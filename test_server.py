#!/usr/bin/env python3
"""
test_server.py -- unit tests for the two functions in
storage_tracker_server.py where a bug destroys data permanently.

    cd ~/Stockroom && python3 test_server.py

Everything else in that server fails loudly and can be retried.
merge_items decides which copy of a box survives when two devices
disagree, and prune_old_tombstones decides which boxes stop existing --
and unlinks their photos on the way out. Those two fail SILENTLY, and
the data does not come back.

Standard library only, matching the server itself.

Note: importing the server module reads (or, on a fresh clone, creates)
stockroom_token.txt and ensures photos/ exists; both are gitignored.
Any test touching photo deletion repoints PHOTOS_DIR at a temporary
directory first -- these tests must never delete a real box photo.
"""

import importlib.util
import os
import shutil
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "storage_tracker_server", Path(__file__).with_name("storage_tracker_server.py")
)
server = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(server)


def ts(days_ago=0):
    """An ISO-8601 Z timestamp `days_ago` days in the past, as the client writes them."""
    moment = datetime.now(timezone.utc) - timedelta(days=days_ago)
    return moment.isoformat().replace("+00:00", "Z")


def box(item_id, updated_at=None, **extra):
    item = {"id": item_id, "box": item_id.upper(), "contents": "", "updatedAt": updated_at}
    if updated_at is None:
        del item["updatedAt"]
    item.update(extra)
    return item


def by_id(items):
    return {i["id"]: i for i in items if "id" in i}


class MergeItemsTests(unittest.TestCase):
    """Newest updatedAt wins per id; neither side's edits are silently dropped."""

    def test_incoming_id_the_server_has_never_seen_is_added(self):
        merged = by_id(server.merge_items([box("a", ts(1))], [box("b", ts(0))]))
        self.assertEqual(set(merged), {"a", "b"})

    def test_newer_incoming_replaces_older_existing(self):
        existing = [box("a", ts(5), contents="old")]
        incoming = [box("a", ts(1), contents="new")]
        self.assertEqual(by_id(server.merge_items(existing, incoming))["a"]["contents"], "new")

    def test_older_incoming_does_not_clobber_newer_existing(self):
        existing = [box("a", ts(1), contents="new")]
        incoming = [box("a", ts(5), contents="old")]
        self.assertEqual(by_id(server.merge_items(existing, incoming))["a"]["contents"], "new")

    def test_identical_timestamps_let_incoming_win(self):
        """Documented tie-break: the comparison is `>=`, so a re-POST is idempotent."""
        same = ts(2)
        existing = [box("a", same, contents="server")]
        incoming = [box("a", same, contents="client")]
        self.assertEqual(by_id(server.merge_items(existing, incoming))["a"]["contents"], "client")

    def test_a_delete_travels_when_the_tombstone_is_newer(self):
        existing = [box("a", ts(3), contents="still here")]
        incoming = [box("a", ts(1), deleted=True)]
        self.assertTrue(by_id(server.merge_items(existing, incoming))["a"]["deleted"])

    def test_an_edit_newer_than_a_tombstone_resurrects_the_box(self):
        """Last write wins in both directions -- this is intended, not a bug."""
        existing = [box("a", ts(3), deleted=True)]
        incoming = [box("a", ts(1), contents="back")]
        self.assertNotIn("deleted", by_id(server.merge_items(existing, incoming))["a"])

    def test_incoming_item_without_an_id_is_ignored(self):
        merged = server.merge_items([box("a", ts(1))], [{"box": "orphan", "updatedAt": ts(0)}])
        self.assertEqual([i["id"] for i in merged], ["a"])

    def test_missing_updatedAt_is_treated_as_oldest(self):
        """`.get("updatedAt", "")` makes a timestamp-less item lose to any real one."""
        existing = [box("a", ts(9), contents="dated")]
        incoming = [box("a", None, contents="undated")]
        self.assertEqual(by_id(server.merge_items(existing, incoming))["a"]["contents"], "dated")

    def test_existing_item_without_an_id_is_dropped_CHARACTERISATION(self):
        """
        NOT an endorsement -- this records current behaviour so a future
        change is a deliberate one. An id-less row already in the data
        file silently disappears on the next sync.
        """
        merged = server.merge_items([{"box": "no id", "updatedAt": ts(1)}], [])
        self.assertEqual(merged, [])


class PruneOldTombstonesTests(unittest.TestCase):
    """Tombstones outlive their usefulness at 30 days; live boxes never expire."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="stockroom-test-"))
        self._real_photos = server.PHOTOS_DIR
        server.PHOTOS_DIR = self.tmp          # never touch the real photos/
        self.assertNotEqual(server.PHOTOS_DIR, self._real_photos)

    def tearDown(self):
        server.PHOTOS_DIR = self._real_photos
        shutil.rmtree(self.tmp, ignore_errors=True)

    def make_photo(self, item_id):
        path = self.tmp / f"{item_id}.jpg"
        path.write_bytes(b"not really a jpeg")
        return path

    def test_live_box_is_kept_however_old(self):
        kept = server.prune_old_tombstones([box("a", ts(4000))])
        self.assertEqual([i["id"] for i in kept], ["a"])

    def test_recent_tombstone_is_kept(self):
        kept = server.prune_old_tombstones([box("a", ts(3), deleted=True)])
        self.assertEqual([i["id"] for i in kept], ["a"])

    def test_tombstone_older_than_the_window_is_dropped(self):
        kept = server.prune_old_tombstones([box("a", ts(31), deleted=True)])
        self.assertEqual(kept, [])

    def test_boundary_just_inside_the_window_is_kept(self):
        kept = server.prune_old_tombstones([box("a", ts(29), deleted=True)])
        self.assertEqual([i["id"] for i in kept], ["a"])

    def test_unparsable_timestamp_is_kept_not_guessed(self):
        kept = server.prune_old_tombstones([box("a", "last Tuesday", deleted=True)])
        self.assertEqual([i["id"] for i in kept], ["a"])

    def test_pruning_a_tombstone_also_deletes_its_photo(self):
        photo = self.make_photo("a")
        server.prune_old_tombstones([box("a", ts(31), deleted=True, photoFilename="a.jpg")])
        self.assertFalse(photo.exists(), "photo of a pruned tombstone should be unlinked")

    def test_keeping_a_tombstone_keeps_its_photo(self):
        photo = self.make_photo("a")
        server.prune_old_tombstones([box("a", ts(3), deleted=True, photoFilename="a.jpg")])
        self.assertTrue(photo.exists(), "photo of a live tombstone must survive")

    def test_live_box_photo_is_never_touched(self):
        photo = self.make_photo("a")
        server.prune_old_tombstones([box("a", ts(4000), photoFilename="a.jpg")])
        self.assertTrue(photo.exists(), "a live box must never lose its photo")

    def test_pruning_without_a_photo_on_disk_does_not_raise(self):
        self.assertEqual(server.prune_old_tombstones([box("a", ts(31), deleted=True)]), [])

    def test_custom_window_is_honoured(self):
        item = [box("a", ts(10), deleted=True)]
        self.assertEqual(server.prune_old_tombstones(item, max_age_days=30), item)
        self.assertEqual(server.prune_old_tombstones(item, max_age_days=5), [])


class MultiPhotoTests(unittest.TestCase):
    """
    Multiple photos per box: `photos` lists them cover first, and
    `photoFilename` mirrors photos[0] for clients that predate the list.
    """

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="stockroom-test-"))
        self._real_photos = server.PHOTOS_DIR
        server.PHOTOS_DIR = self.tmp          # never touch the real photos/
        self.assertNotEqual(server.PHOTOS_DIR, self._real_photos)

    def tearDown(self):
        server.PHOTOS_DIR = self._real_photos
        shutil.rmtree(self.tmp, ignore_errors=True)

    def make_photo(self, name, age_seconds=0, folder=None):
        folder = folder or self.tmp
        folder.mkdir(exist_ok=True)
        path = folder / name
        path.write_bytes(b"not really a jpeg")
        if age_seconds:
            t = datetime.now(timezone.utc).timestamp() - age_seconds
            os.utime(path, (t, t))
        return path

    # -- normalize_photos -------------------------------------------------

    def test_legacy_single_photo_becomes_a_one_item_list(self):
        item = server.normalize_photos(box("a", ts(0), photoFilename="a.jpg"))
        self.assertEqual(item["photos"], ["a.jpg"])
        self.assertEqual(item["photoFilename"], "a.jpg")

    def test_cover_follows_the_first_photo(self):
        item = server.normalize_photos(box("a", ts(0), photos=["a-x1.jpg", "a.jpg"], photoFilename="a-x1.jpg"))
        self.assertEqual(item["photos"], ["a-x1.jpg", "a.jpg"])
        self.assertEqual(item["photoFilename"], "a-x1.jpg")

    def test_older_client_setting_photoFilename_is_folded_in_at_the_front(self):
        item = server.normalize_photos(box("a", ts(0), photos=["a-x1.jpg"], photoFilename="a.jpg"))
        self.assertEqual(item["photos"], ["a.jpg", "a-x1.jpg"])

    def test_removing_every_photo_clears_the_cover(self):
        item = server.normalize_photos(box("a", ts(0), photos=[], photoFilename=None))
        self.assertEqual(item["photos"], [])
        self.assertIsNone(item["photoFilename"])

    def test_box_without_photos_gets_no_new_keys(self):
        item = server.normalize_photos(box("a", ts(0)))
        self.assertNotIn("photos", item)

    def test_another_boxs_photo_cannot_be_claimed(self):
        item = server.normalize_photos(box("a", ts(0), photos=["b.jpg", "../x.jpg", "a-ok.jpg", "a-ok.jpg"]))
        self.assertEqual(item["photos"], ["a-ok.jpg"])

    def test_list_is_not_truncated_server_side(self):
        names = ["a.jpg"] + [f"a-{n}.jpg" for n in range(8)]
        item = server.normalize_photos(box("a", ts(0), photos=names))
        self.assertEqual(len(item["photos"]), 9, "dropping photos on the server would be data loss")

    # -- photo keys --------------------------------------------------------

    def test_photo_key_accepts_an_extra_photo_suffix(self):
        self.assertIsNotNone(server.photo_path_for_id("b_mtg0irgd_o05xzc-mvx1a2"))

    def test_photo_key_rejects_dots_and_double_suffixes(self):
        for bad in ("a.b", "a-b-c", "a-", "-a", "a b", "a-b/c"):
            self.assertIsNone(server.photo_path_for_id(bad), bad)

    # -- pruning a tombstone ----------------------------------------------

    def test_pruning_a_tombstone_deletes_all_its_photos(self):
        p1, p2, p3 = self.make_photo("a.jpg"), self.make_photo("a-x1.jpg"), self.make_photo("a-x2.jpg")
        server.prune_old_tombstones([box("a", ts(31), deleted=True,
                                         photos=["a-x1.jpg", "a.jpg", "a-x2.jpg"], photoFilename="a-x1.jpg")])
        for p in (p1, p2, p3):
            self.assertFalse(p.exists(), p.name)

    def test_pruning_never_deletes_another_boxs_photo(self):
        other = self.make_photo("b.jpg")
        server.prune_old_tombstones([box("a", ts(31), deleted=True, photos=["b.jpg"])])
        self.assertTrue(other.exists())

    # -- orphan sweep -------------------------------------------------------

    def test_referenced_photos_are_left_alone(self):
        p = self.make_photo("a-x1.jpg", age_seconds=10 * 86400)
        server.sweep_orphan_photos([box("a", ts(0), photos=["a-x1.jpg"])])
        self.assertTrue(p.exists())

    def test_tombstones_still_count_as_references(self):
        p = self.make_photo("a.jpg", age_seconds=10 * 86400)
        server.sweep_orphan_photos([box("a", ts(3), deleted=True, photoFilename="a.jpg")])
        self.assertTrue(p.exists())

    def test_fresh_unreferenced_upload_gets_a_grace_period(self):
        p = self.make_photo("a-new.jpg", age_seconds=60)
        server.sweep_orphan_photos([box("a", ts(0), photos=["a.jpg"])])
        self.assertTrue(p.exists(), "the iPhone app uploads before it syncs the box")

    def test_removed_photo_is_moved_aside_not_deleted(self):
        self.make_photo("a-gone.jpg", age_seconds=2 * 86400)
        moved, _, _ = server.sweep_orphan_photos([box("a", ts(0), photos=["a.jpg"])])
        self.assertEqual(moved, 1)
        self.assertFalse((self.tmp / "a-gone.jpg").exists())
        self.assertTrue((self.tmp / "removed" / "a-gone.jpg").exists())

    def test_a_photo_referenced_again_is_restored(self):
        self.make_photo("a-back.jpg", folder=self.tmp / "removed")
        _, restored, _ = server.sweep_orphan_photos([box("a", ts(0), photos=["a-back.jpg"])])
        self.assertEqual(restored, 1)
        self.assertTrue((self.tmp / "a-back.jpg").exists())

    def test_removed_photos_are_deleted_after_the_window(self):
        old = self.make_photo("a-old.jpg", age_seconds=31 * 86400, folder=self.tmp / "removed")
        recent = self.make_photo("a-recent.jpg", age_seconds=5 * 86400, folder=self.tmp / "removed")
        server.sweep_orphan_photos([])
        self.assertFalse(old.exists())
        self.assertTrue(recent.exists())


class PathTraversalTests(unittest.TestCase):
    """Both file resolvers refuse to escape their directory."""

    def test_photo_path_rejects_separators_and_parents(self):
        for bad in ("../stockroom_token.txt", "a/b", "a\\b", ".", "..", ""):
            self.assertIsNone(server.photo_path_for_id(bad), bad)

    def test_photo_path_accepts_a_plain_id(self):
        self.assertIsNotNone(server.photo_path_for_id("b_mtg0irgd_o05xzc"))

    def test_icon_path_rejects_traversal_and_unknown_suffixes(self):
        for bad in ("../stockroom_token.txt", "../gemini_api_key.txt", "sub/dir.png",
                    "apple-touch-icon.txt", "apple-touch-icon", "..", ""):
            self.assertIsNone(server.icon_path_for(bad), bad)

    def test_icon_path_resolves_the_real_icons(self):
        self.assertIsNotNone(server.icon_path_for("apple-touch-icon.png"))
        self.assertIsNotNone(server.icon_path_for("favicon-32.png"))

    def test_icon_suffix_allowlist_refuses_a_non_image_that_really_exists(self):
        """
        The other icon tests pass even with the suffix check deleted,
        because a rejected name also happens not to exist on disk. The
        allowlist only earns its keep when a non-image file IS sitting
        in icons/ -- so put one there and prove it stays unreadable.
        """
        tmp = Path(tempfile.mkdtemp(prefix="stockroom-icons-"))
        real = server.ICONS_DIR
        server.ICONS_DIR = tmp
        try:
            (tmp / "secrets.txt").write_text("a token would live here")
            (tmp / "logo.png").write_bytes(b"not really a png")
            self.assertIsNone(server.icon_path_for("secrets.txt"))
            self.assertIsNotNone(server.icon_path_for("logo.png"))
        finally:
            server.ICONS_DIR = real
            shutil.rmtree(tmp, ignore_errors=True)


class UsersAndDeleteLockTests(unittest.TestCase):
    """Family users: own tokens, and a canDelete switch the server enforces.

    A bug here either lets a locked user delete (the thing this exists to
    stop) or blocks a legitimate edit, so both directions are pinned.
    """

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="stockroom-users-"))
        self._real_users = server.USERS_FILE
        server.USERS_FILE = self.tmp / "stockroom_users.json"   # never the real file

    def tearDown(self):
        server.USERS_FILE = self._real_users
        shutil.rmtree(self.tmp, ignore_errors=True)

    # -- tokens -------------------------------------------------------------

    def test_owner_token_can_always_delete(self):
        who = server.principal_for_token(server.SYNC_TOKEN)
        self.assertTrue(who["owner"])
        self.assertTrue(who["canDelete"])

    def test_new_user_starts_locked_with_their_own_token(self):
        u = server.add_user("Alex")
        self.assertNotEqual(u["token"], server.SYNC_TOKEN)
        who = server.principal_for_token(u["token"])
        self.assertEqual(who["name"], "Alex")
        self.assertFalse(who["owner"])
        self.assertFalse(who["canDelete"])

    def test_switch_takes_effect_without_a_restart(self):
        u = server.add_user("Blake")
        server.update_user(u["id"], canDelete=True)
        self.assertTrue(server.principal_for_token(u["token"])["canDelete"])

    def test_reset_token_disconnects_the_old_one(self):
        u = server.add_user("Casey")
        server.update_user(u["id"], token="f" * 32)
        self.assertIsNone(server.principal_for_token(u["token"]))
        self.assertIsNotNone(server.principal_for_token("f" * 32))

    def test_removed_user_token_stops_working(self):
        u = server.add_user("Alex")
        self.assertTrue(server.remove_user(u["id"]))
        self.assertIsNone(server.principal_for_token(u["token"]))

    def test_empty_and_unknown_tokens_are_refused(self):
        server.add_user("Alex")
        self.assertIsNone(server.principal_for_token(""))
        self.assertIsNone(server.principal_for_token("nope"))

    def test_duplicate_names_and_blank_names_are_rejected(self):
        server.add_user("Alex")
        with self.assertRaises(ValueError):
            server.add_user("alex")
        with self.assertRaises(ValueError):
            server.add_user("   ")

    def test_missing_or_corrupt_users_file_means_no_users(self):
        self.assertEqual(server.load_users(), [])
        server.USERS_FILE.write_text("{not json", encoding="utf-8")
        self.assertEqual(server.load_users(), [])

    # -- apply_delete_lock --------------------------------------------------

    def test_locked_delete_of_a_live_box_is_dropped(self):
        existing = [box("a", ts(2), contents="keep me")]
        incoming = [box("a", ts(0), deleted=True)]
        locked = server.apply_delete_lock(existing, incoming)
        merged = by_id(server.merge_items(existing, locked))
        self.assertFalse(merged["a"].get("deleted"))
        self.assertEqual(merged["a"]["contents"], "keep me")

    def test_locked_user_can_still_add_and_edit(self):
        existing = [box("a", ts(2), contents="old")]
        incoming = [box("a", ts(0), contents="new"), box("b", ts(0), contents="added")]
        merged = by_id(server.merge_items(existing, server.apply_delete_lock(existing, incoming)))
        self.assertEqual(merged["a"]["contents"], "new")
        self.assertIn("b", merged)

    def test_locked_tombstone_for_an_unknown_box_is_dropped(self):
        self.assertEqual(server.apply_delete_lock([], [box("z", ts(0), deleted=True)]), [])

    def test_tombstone_the_server_already_has_passes_through(self):
        existing = [box("a", ts(2), deleted=True)]
        incoming = [box("a", ts(2), deleted=True)]
        self.assertEqual(len(server.apply_delete_lock(existing, incoming)), 1)

    def test_locked_photo_removal_is_put_back(self):
        existing = [box("a", ts(2), photos=["a.jpg", "a-x1.jpg"], photoFilename="a.jpg")]
        incoming = [box("a", ts(0), photos=["a-x1.jpg"], photoFilename="a-x1.jpg")]
        item = server.apply_delete_lock(existing, incoming)[0]
        self.assertEqual(item["photos"], ["a-x1.jpg", "a.jpg"])   # cover choice kept
        self.assertEqual(item["photoFilename"], "a-x1.jpg")

    def test_locked_user_can_add_a_photo(self):
        existing = [box("a", ts(2), photos=["a.jpg"], photoFilename="a.jpg")]
        incoming = [box("a", ts(0), photos=["a.jpg", "a-n2.jpg"], photoFilename="a.jpg")]
        self.assertEqual(server.apply_delete_lock(existing, incoming)[0]["photos"], ["a.jpg", "a-n2.jpg"])

    def test_lock_does_not_mutate_the_incoming_item(self):
        existing = [box("a", ts(2), photos=["a.jpg"], photoFilename="a.jpg")]
        sent = box("a", ts(0), photos=[], photoFilename=None)
        server.apply_delete_lock(existing, [sent])
        self.assertEqual(sent["photos"], [])

    # -- is_direct_local_request ---------------------------------------------

    def test_users_page_only_for_a_direct_browser_on_this_mac(self):
        ok = server.is_direct_local_request
        self.assertTrue(ok("127.0.0.1", {"Host": "localhost:8787"}))
        self.assertTrue(ok("::1", {"Host": "[::1]:8787"}))
        self.assertTrue(ok("::ffff:127.0.0.1", {"Host": "127.0.0.1:8787"}))
        # tailscale serve also arrives from loopback, but with these headers
        self.assertFalse(ok("127.0.0.1", {"Host": "localhost:8787", "X-Forwarded-For": "100.101.1.2"}))
        self.assertFalse(ok("127.0.0.1", {"Host": "localhost:8787", "Tailscale-User-Login": "x@y"}))
        self.assertFalse(ok("127.0.0.1", {"Host": "mac.tailnet.ts.net"}))   # tailnet hostname
        self.assertFalse(ok("127.0.0.1", {"Host": "evil.example:8787"}))    # DNS rebinding
        self.assertFalse(ok("100.101.1.2", {"Host": "localhost:8787"}))     # a tailnet phone
        self.assertFalse(ok("192.168.68.20", {"Host": "localhost:8787"}))   # LAN
        self.assertFalse(ok("garbage", {"Host": "localhost"}))


class InstallOnPhoneTests(unittest.TestCase):
    """The Users page's Install on iPhone button: device list + background job."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="stockroom-install-"))
        self._real = (server.USERS_FILE, server.INSTALL_SCRIPT)
        server.USERS_FILE = self.tmp / "stockroom_users.json"
        server._install_job = {"state": "idle"}

    def tearDown(self):
        server.USERS_FILE, server.INSTALL_SCRIPT = self._real
        shutil.rmtree(self.tmp, ignore_errors=True)

    def fake_script(self, body):
        script = self.tmp / "install-for.sh"
        script.write_text("#!/bin/sh\n" + body + "\n")
        script.chmod(0o755)
        server.INSTALL_SCRIPT = script

    def wait(self):
        import time
        for _ in range(100):
            if server.install_status()["state"] != "running":
                return server.install_status()
            time.sleep(0.05)
        self.fail("install job never finished")

    def test_only_paired_physical_iphones_are_listed_plugged_in_first(self):
        def dev(udid, name, platform="iOS", reality="physical", pairing="paired", transport="localNetwork"):
            return {"hardwareProperties": {"udid": udid, "platform": platform, "reality": reality,
                                           "marketingName": "iPhone Duo"},
                    "deviceProperties": {"name": name},
                    "connectionProperties": {"pairingState": pairing, "transportType": transport}}
        data = {"result": {"devices": [
            dev("00008150-000A11112222333E", "Wi-Fi phone"),
            dev("00008150-000B11112222333E", "Cable phone", transport="wired"),
            dev("00008150-000C11112222333E", "Simulator", reality="virtual"),
            dev("00008150-000D11112222333E", "Watch", platform="watchOS"),
            dev("00008150-000E11112222333E", "Unpaired", pairing="unpaired"),
            dev("bad udid; rm -rf /", "Weird"),
        ]}}
        phones = server.parse_devicectl_devices(data)
        self.assertEqual([ph["name"] for ph in phones], ["Cable phone", "Wi-Fi phone"])
        self.assertTrue(phones[0]["pluggedIn"])
        self.assertEqual(server.parse_devicectl_devices({}), [])

    def test_successful_install_records_the_phone(self):
        self.fake_script('echo "Building for $6"; echo "args: $*"; exit 0')
        u = server.add_user("Alex")
        self.assertTrue(server.start_install(u, "00008150-000B11112222333E", "Alex's iPhone"))
        job = self.wait()
        self.assertEqual(job["state"], "done")
        self.assertIn("--device 00008150-000B11112222333E --device-name Alex's iPhone --yes Alex", job["log"][-1])
        saved = server.load_users()[0]
        self.assertEqual(saved["phoneName"], "Alex's iPhone")
        self.assertEqual(saved["token"], u["token"])          # untouched

    def test_failed_install_is_reported_and_records_nothing(self):
        self.fake_script('echo "Build failed." >&2; exit 1')
        u = server.add_user("Alex")
        server.start_install(u, "00008150-000B11112222333E", "Alex's iPhone")
        job = self.wait()
        self.assertEqual(job["state"], "failed")
        self.assertIn("Build failed.", job["log"])
        self.assertNotIn("phoneName", server.load_users()[0])

    def test_only_one_install_at_a_time(self):
        self.fake_script("sleep 1")
        u = server.add_user("Alex")
        self.assertTrue(server.start_install(u, "00008150-000B11112222333E", "A"))
        self.assertFalse(server.start_install(u, "00008150-000B11112222333E", "A"))
        self.wait()


if __name__ == "__main__":
    unittest.main(verbosity=2)
