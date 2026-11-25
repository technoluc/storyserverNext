"""Offline regressions for shared-account session protection."""
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

_import_state = tempfile.TemporaryDirectory()
with patch.dict(os.environ, {"CATALOG_DB": str(Path(_import_state.name) / "catalog.sqlite3")}):
    from app.discovery import CatalogIndex, NextoryError, CATEGORIES
    from app.nextory import NextoryBackend


class AccountSafetyTests(unittest.TestCase):
    def test_existing_session_is_not_recreated_on_age(self):
        backend = NextoryBackend()
        backend._authed_at = 1.0
        with patch.object(backend._api, "post") as post:
            backend._ensure_login()
            post.assert_not_called()

    def test_rejected_session_is_not_reclaimed(self):
        for status in (401, 403, 429):
            with self.subTest(status=status):
                backend = NextoryBackend()
                backend._authed_at = 1.0
                response = Mock(status_code=status)
                with patch.object(backend._api, "get", return_value=response) as get, \
                     patch.object(backend._api, "post") as post:
                    with self.assertRaises(NextoryError):
                        backend._authenticated_get_json("https://api.nextory.com/example", "test")
                    self.assertTrue(backend.access_paused)
                    with self.assertRaises(NextoryError):
                        backend._authenticated_get_json("https://api.nextory.com/example", "test")
                    self.assertEqual(get.call_count, 1)
                    post.assert_not_called()

    def test_missing_cover_does_not_login(self):
        backend = NextoryBackend()
        with patch.object(backend, "_ensure_login") as login:
            with self.assertRaises(NextoryError):
                backend.get_cover_jpeg(12345)
            login.assert_not_called()


class CatalogSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "catalog.sqlite3"
        self.index = CatalogIndex(self.path)
        self.key = CATEGORIES[0][0]

    def test_repeat_page_is_persistently_paused(self):
        with patch("app.discovery.parse_book_ids", return_value=[12345]), \
             patch.object(self.index, "_fetch_public", return_value="page") as fetch, \
             patch.object(self.index, "_hydrate", return_value=[]) as hydrate:
            self.index.fill_next_category_page(self.key)
            self.index.fill_next_category_page(self.key)
            self.assertEqual(hydrate.call_count, 1)
            self.assertEqual(fetch.call_count, 2)
        reopened = CatalogIndex(self.path)
        with patch.object(reopened, "_fetch_public") as fetch:
            self.assertIsNone(reopened.fill_next_category_page(self.key))
            fetch.assert_not_called()
        self.assertEqual(reopened.statistics()["pausedCategories"][self.key], "repeated-source-page")

    def test_failed_page_has_persistent_cooldown(self):
        with patch.object(self.index, "_fetch_public", side_effect=NextoryError("offline")) as fetch:
            with self.assertRaises(NextoryError):
                self.index.fill_next_category_page(self.key)
            self.assertIsNone(self.index.fill_next_category_page(self.key))
            self.assertEqual(fetch.call_count, 1)

    def test_negative_preview_is_not_repeated(self):
        with patch("app.discovery.nextory.get_product_preview", return_value=None) as get, \
             patch("app.discovery.time.sleep"):
            self.index._hydrate([12345])
            self.index._hydrate([12345])
            get.assert_called_once_with(12345)

    def test_auth_failure_stops_hydration(self):
        with patch("app.discovery.nextory.get_product_preview", side_effect=NextoryError("denied")) as get:
            with self.assertRaises(NextoryError):
                self.index._hydrate([12345, 12346])
            get.assert_called_once_with(12345)


if __name__ == "__main__":
    unittest.main()
