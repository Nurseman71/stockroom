#!/bin/bash
#
# install-for.sh — install Stockroom on a family member's iPhone, already
# connected with THEIR token (from the Users page), so nothing is typed or
# pasted on the phone.
#
#   ~/Stockroom/ios/install-for.sh Alex
#
# Usually you don't run this yourself: the Users page's "Install on iPhone"
# button runs it as
#   install-for.sh --device <udid> --device-name <name> --yes <Name>
# which skips the questions below.
#
# Before running: plug the phone into this Mac with a cable, unlock it, tap
# Trust, and turn on Settings > Privacy & Security > Developer Mode (once).
#
# The token and server address are baked into the app at build time and come
# from files that are never committed (the repo is public):
#   ~/Stockroom/stockroom_users.json                       (Users page)
#   ~/Stockroom/ios/Stockroom/Config/Stockroom.local.xcconfig (Tailscale host)
# The build happens in a private temp folder that is deleted afterwards,
# because the built app contains the token.
#
# After "Reset token" on the Users page, run this again for that person.

set -euo pipefail

UDID=""; DNAME=""; ASSUME_YES=no; NAME=""
while [ $# -gt 0 ]; do
    case "$1" in
        --device) UDID="${2:-}"; shift 2 ;;
        --device-name) DNAME="${2:-}"; shift 2 ;;
        --yes) ASSUME_YES=yes; shift ;;
        -*) echo "Unknown option $1" >&2; exit 64 ;;
        *) NAME="$1"; shift ;;
    esac
done
if [ -z "$NAME" ]; then
    echo "Usage: $0 [--device UDID --device-name NAME --yes] <name from the Users page>" >&2
    exit 64
fi

IOS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$IOS_DIR/.." && pwd)"
USERS_FILE="$REPO/stockroom_users.json"
LOCAL_CFG="$IOS_DIR/Stockroom/Config/Stockroom.local.xcconfig"
PROJECT="$IOS_DIR/Stockroom/Stockroom.xcodeproj"

die() { echo "✗ $*" >&2; exit 1; }

[ -r "$USERS_FILE" ] || die "No users yet — add them at http://localhost:8787/users first."
[ -r "$LOCAL_CFG" ] || die "Missing $LOCAL_CFG (it holds the Tailscale hostname)."

# --- who -------------------------------------------------------------------
# Prints "<exact name>\t<token>\t<canDelete>" for a case-insensitive match.
USER_LINE="$(/usr/bin/python3 -I - "$USERS_FILE" "$NAME" <<'PY'
import json, sys
users = json.load(open(sys.argv[1])).get("users", [])
want = sys.argv[2].strip().lower()
for u in users:
    if u.get("name", "").lower() == want and u.get("token"):
        print(f'{u["name"]}\t{u["token"]}\t{"on" if u.get("canDelete") else "off"}')
        break
else:
    names = ", ".join(u.get("name", "?") for u in users) or "none"
    print(f"No user called {sys.argv[2]!r}. Users: {names}", file=sys.stderr)
    sys.exit(1)
PY
)" || exit 1
IFS=$'\t' read -r WHO TOKEN CAN_DELETE <<<"$USER_LINE"

DOMAIN="$(sed -n 's/^[[:space:]]*STOCKROOM_LINK_DOMAIN[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' "$LOCAL_CFG" | tail -1)"
[ -n "$DOMAIN" ] && [ "$DOMAIN" != "stockroom.invalid" ] || die "STOCKROOM_LINK_DOMAIN isn't set in $LOCAL_CFG."
SERVER="https://$DOMAIN/stockroom"

# --- which phone -----------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/stockroom-install.XXXXXX")"
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

if [ -z "$UDID" ]; then
echo "Looking for iPhones connected to this Mac…"
xcrun devicectl list devices --json-output "$WORK/devices.json" >/dev/null 2>&1 \
    || die "Couldn't list devices (is Xcode installed and opened at least once?)."

# "<udid>\t<name>\t<model>\t<wired yes/no>" for each paired iPhone.
/usr/bin/python3 -I - "$WORK/devices.json" > "$WORK/phones.tsv" <<'PY'
import json, sys
devs = json.load(open(sys.argv[1])).get("result", {}).get("devices", [])
for d in devs:
    hw, dp, cp = d.get("hardwareProperties", {}), d.get("deviceProperties", {}), d.get("connectionProperties", {})
    if hw.get("platform") != "iOS" or hw.get("reality") == "virtual":
        continue
    if cp.get("pairingState") != "paired":
        continue
    wired = "yes" if cp.get("transportType") == "wired" else "no"
    print("\t".join([hw.get("udid", ""), dp.get("name", "?"), hw.get("marketingName", ""), wired]))
PY

COUNT="$(grep -c . "$WORK/phones.tsv" || true)"
[ "$COUNT" -gt 0 ] || die "No iPhone found. Plug it in, unlock it, tap Trust, and try again."

echo
i=0; DEFAULT=""
while IFS=$'\t' read -r udid dname model wired; do
    i=$((i + 1))
    note=""; [ "$wired" = "yes" ] && note="  ← plugged in" && [ -z "$DEFAULT" ] && DEFAULT=$i
    printf '  %d) %s (%s)%s\n' "$i" "$dname" "$model" "$note"
done < "$WORK/phones.tsv"
echo
read -r -p "Which phone is ${WHO}'s? [${DEFAULT:-number}] " PICK
PICK="${PICK:-$DEFAULT}"
[[ "$PICK" =~ ^[0-9]+$ ]] && [ "$PICK" -ge 1 ] && [ "$PICK" -le "$COUNT" ] || die "Not a valid choice."
IFS=$'\t' read -r UDID DNAME _ _ < <(sed -n "${PICK}p" "$WORK/phones.tsv")
fi
DNAME="${DNAME:-$UDID}"

echo
echo "  Person:   $WHO   (deleting: $CAN_DELETE — change any time on the Users page)"
echo "  Phone:    $DNAME"
echo "  Server:   $SERVER"
echo
if [ "$ASSUME_YES" != yes ]; then
    echo "This phone will sync as $WHO from now on. Don't do this to your own phone."
    read -r -p "Install? [y/N] " OK
    [[ "$OK" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }
fi

# --- build -------------------------------------------------------------------
# Passed as an xcconfig file, not on the command line, so the token never
# shows up in the process list.
umask 077
cat > "$WORK/preset.xcconfig" <<CFG
STOCKROOM_PRESET_NAME = $WHO
STOCKROOM_PRESET_SERVER = $SERVER
STOCKROOM_PRESET_TOKEN = $TOKEN
CFG

echo
echo "Building for $WHO (a minute or two)…"
if ! xcodebuild -project "$PROJECT" -scheme Stockroom -configuration Debug \
        -destination "id=$UDID" -derivedDataPath "$WORK/build" \
        -xcconfig "$WORK/preset.xcconfig" -allowProvisioningUpdates \
        build > "$WORK/build.log" 2>&1; then
    echo "--- last 30 lines of the build log ---" >&2
    tail -30 "$WORK/build.log" >&2
    die "Build failed."
fi

APP="$WORK/build/Build/Products/Debug-iphoneos/Stockroom.app"
[ -d "$APP" ] || die "Build finished but Stockroom.app wasn't where expected."

echo "Installing on $DNAME…"
xcrun devicectl device install app --device "$UDID" "$APP" > "$WORK/install.log" 2>&1 \
    || { tail -20 "$WORK/install.log" >&2; die "Install failed — is the phone unlocked?"; }

echo
echo "✓ Stockroom is on $DNAME, set up for $WHO."
echo "  Open it once there (Tailscale must be connected) — it syncs on its own."
