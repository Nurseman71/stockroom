#!/bin/bash
#
# backup_stockroom.sh — twice-daily backup of Stockroom.
#
# Backs up the whole app folder EXCLUDING git history and logs, which means the
# gitignored local data (stockroom_data.json, photos/, stockroom_token.txt,
# gemini_api_key.txt) is captured — that data exists nowhere else.
#
# Two tiers:
#   1. ~/StockroomBackup            (internal, APFS)  — keep 14
#   2. /Volumes/My Passport/...     (external, NTFS)  — keep 60
# Tier 1 always runs. Tier 2 is best-effort: if the external is unmounted or the
# Paragon/UFSD driver has dropped it to read-only, tier 1 still succeeds and the
# run reports a warning. A driver failure never means zero backups for the day.
#
# ADDITIVE ONLY. Never rsync --delete, never touch anything this script did not
# create. Pruning matches stockroom_*.tar.gz inside its own two folders only.

set -u
set -o pipefail

APP_DIR="$HOME/Stockroom"
LOCAL_DEST="$HOME/StockroomBackup"
EXT_VOL="/Volumes/My Passport"
EXT_DEST="$EXT_VOL/StockroomBackup"
KEEP_LOCAL=14
KEEP_EXT=60
LOG="$APP_DIR/backup.log"
VK_CONF="$HOME/.vaultkeeper.conf"

STAMP="$(date '+%Y-%m-%d_%H%M')"        # no colons — NTFS rejects them
ARCHIVE="stockroom_${STAMP}.tar.gz"

WARNINGS=""

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

# Push to Home Assistant, reusing Vaultkeeper's credentials. Failure-only.
notify_failure() {
    local msg
    msg="$(printf '%s' "$1" | tr -d '"\\' | tr '\n' ' ')"
    if [ ! -r "$VK_CONF" ]; then
        log "note: $VK_CONF not readable — no push sent"
        return
    fi
    # shellcheck disable=SC1090
    . "$VK_CONF" 2>/dev/null || true
    case "$(printf '%s' "${HOME_ASSISTANT_ENABLED:-}" | tr 'A-Z' 'a-z')" in
        1|true|yes|on) ;;
        *) log "note: Home Assistant disabled in $VK_CONF — no push sent"; return ;;
    esac
    if [ -z "${HOME_ASSISTANT_URL:-}" ] || [ -z "${HOME_ASSISTANT_TOKEN:-}" ] \
       || [ -z "${HOME_ASSISTANT_NOTIFY_SERVICE:-}" ]; then
        log "note: Home Assistant config incomplete — no push sent"
        return
    fi
    if curl -sS -m 15 -o /dev/null -X POST \
        -H "Authorization: Bearer ${HOME_ASSISTANT_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"title\":\"Stockroom backup failed\",\"message\":\"${msg}\"}" \
        "${HOME_ASSISTANT_URL%/}/api/services/notify/${HOME_ASSISTANT_NOTIFY_SERVICE}"
    then
        log "note: failure push sent to Home Assistant"
    else
        log "note: failure push to Home Assistant did not go through"
    fi
}

die() {
    log "FAIL: $1"
    notify_failure "$1"
    exit 1
}

# Keep the newest $2 archives in $1. Only ever removes stockroom_*.tar.gz.
prune() {
    local dir="$1" keep="$2" f
    [ -d "$dir" ] || return 0
    ls -1t "$dir"/stockroom_*.tar.gz 2>/dev/null | tail -n +"$((keep + 1))" | while IFS= read -r f; do
        rm -f "$f" && log "pruned $(basename "$f")"
    done
}

log "=== run start ($ARCHIVE) ==="

[ -d "$APP_DIR" ] || die "source folder $APP_DIR is missing"
[ -f "$APP_DIR/stockroom_data.json" ] || die "stockroom_data.json not found in $APP_DIR"

mkdir -p "$LOCAL_DEST" || die "could not create $LOCAL_DEST"
chmod 700 "$LOCAL_DEST" 2>/dev/null

# ---- tier 1: build and verify on internal APFS -----------------------------
TMP="$LOCAL_DEST/.${ARCHIVE}.partial"
rm -f "$TMP"

tar -czf "$TMP" -C "$APP_DIR" \
    --exclude='./.git' \
    --exclude='./__pycache__' \
    --exclude='./server.log' \
    --exclude='./server.err' \
    --exclude='./backup.log' \
    --exclude='.DS_Store' \
    . || { rm -f "$TMP"; die "tar failed while building the archive"; }

tar -tzf "$TMP" >/dev/null 2>&1 \
    || { rm -f "$TMP"; die "archive failed its integrity check (unreadable tar)"; }

tar -tzf "$TMP" 2>/dev/null | grep -q '^\./stockroom_data\.json$' \
    || { rm -f "$TMP"; die "archive built but does not contain stockroom_data.json"; }

mv "$TMP" "$LOCAL_DEST/$ARCHIVE" || die "could not finalize $LOCAL_DEST/$ARCHIVE"
chmod 600 "$LOCAL_DEST/$ARCHIVE" 2>/dev/null

SRC_SUM="$(shasum -a 256 "$LOCAL_DEST/$ARCHIVE" | awk '{print $1}')"
SIZE="$(wc -c < "$LOCAL_DEST/$ARCHIVE" | tr -d ' ')"
printf '%s  %s\n' "$SRC_SUM" "$ARCHIVE" >> "$LOCAL_DEST/checksums.txt"
log "internal OK: $LOCAL_DEST/$ARCHIVE (${SIZE} bytes, sha256 ${SRC_SUM:0:12}...)"

# ---- tier 2: copy to the external, best-effort -----------------------------
if ! /sbin/mount | grep -qF " on $EXT_VOL ("; then
    WARNINGS="external drive not mounted at '$EXT_VOL' — internal copy only"
    log "WARN: $WARNINGS"
else
    if ! mkdir -p "$EXT_DEST" 2>/dev/null; then
        WARNINGS="could not create $EXT_DEST (read-only mount?) — internal copy only"
        log "WARN: $WARNINGS"
    elif ! touch "$EXT_DEST/.writetest" 2>/dev/null; then
        WARNINGS="$EXT_VOL is mounted but not writable (Paragon/UFSD dropped to read-only?) — internal copy only"
        log "WARN: $WARNINGS"
    else
        rm -f "$EXT_DEST/.writetest"
        ETMP="$EXT_DEST/.${ARCHIVE}.partial"
        rm -f "$ETMP"
        if ! cp "$LOCAL_DEST/$ARCHIVE" "$ETMP" 2>/dev/null; then
            rm -f "$ETMP"
            WARNINGS="copy to external failed — internal copy only"
            log "WARN: $WARNINGS"
        else
            DST_SUM="$(shasum -a 256 "$ETMP" 2>/dev/null | awk '{print $1}')"
            if [ "$DST_SUM" != "$SRC_SUM" ]; then
                rm -f "$ETMP"
                WARNINGS="external copy did not match checksum (read-back mismatch) — internal copy only"
                log "WARN: $WARNINGS"
            else
                mv "$ETMP" "$EXT_DEST/$ARCHIVE" 2>/dev/null \
                    && log "external OK: $EXT_DEST/$ARCHIVE (verified)" \
                    || { WARNINGS="could not finalize the external copy"; log "WARN: $WARNINGS"; }
                prune "$EXT_DEST" "$KEEP_EXT"
            fi
        fi
    fi
fi

prune "$LOCAL_DEST" "$KEEP_LOCAL"

# ---- log rotation ----------------------------------------------------------
if [ -f "$LOG" ] && [ "$(wc -l < "$LOG" | tr -d ' ')" -gt 2000 ]; then
    tail -n 1000 "$LOG" > "$LOG.rotate" && mv "$LOG.rotate" "$LOG"
fi

if [ -n "$WARNINGS" ]; then
    log "=== run finished WITH WARNING ==="
    notify_failure "Backup made it to the internal disk but not the external drive: $WARNINGS"
    exit 2
fi

log "=== run finished clean ==="
exit 0
