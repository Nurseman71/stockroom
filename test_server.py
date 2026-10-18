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


if __name__ == "__main__":
    unittest.main(verbosity=2)
