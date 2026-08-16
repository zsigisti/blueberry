#!/usr/bin/env python3
"""Unit tests for auto-bump.py's recipe parsing — no network.

Run: python3 tools/test/test-auto-bump.py
"""
import importlib.util
import os
import tomllib
import unittest

TOP = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_spec = importlib.util.spec_from_file_location(
    "auto_bump", os.path.join(TOP, "tools", "pkg", "auto-bump.py"))
ab = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ab)

ONE_SOURCE = '''
[package]
name = "foo"
version = "1.0"

[[source]]
url    = "https://example.org/foo-1.0.tar.gz"
sha256 = "%s"
''' % ("a" * 64)

WITH_UPSTREAM = '''
[package]
name = "foo"
version = "1.0"

[upstream]
url   = "https://example.org/download/"
regex = "foo-([0-9.]+)\\\\.tar"

[[source]]
url    = "https://example.org/foo-1.0.tar.gz"
sha256 = "%s"
''' % ("a" * 64)

TWO_SOURCES = WITH_UPSTREAM + '''
[[source]]
url    = "foo-cve-2026-1.patch"
sha256 = "%s"
''' % ("b" * 64)


class TestRecipeSources(unittest.TestCase):
    def test_single_source(self):
        urls, shas = ab.recipe_sources(tomllib.loads(ONE_SOURCE))
        self.assertEqual(urls, ["https://example.org/foo-1.0.tar.gz"])
        self.assertEqual(len(shas), 1)

    def test_upstream_url_is_not_a_source(self):
        """[upstream] url= says where to look for new versions; it is not a
        source. Counting it made every tracked recipe refuse to bump."""
        urls, shas = ab.recipe_sources(tomllib.loads(WITH_UPSTREAM))
        self.assertEqual(urls, ["https://example.org/foo-1.0.tar.gz"])
        self.assertEqual(len(shas), 1)

    def test_real_multi_source_still_counted(self):
        urls, shas = ab.recipe_sources(tomllib.loads(TWO_SOURCES))
        self.assertEqual(len(urls), 2)
        self.assertEqual(len(shas), 2)

    def test_every_shipped_recipe_parses(self):
        import glob
        for f in glob.glob(os.path.join(TOP, "packages", "*", "bpm.toml")):
            with open(f, "rb") as fh:
                ab.recipe_sources(tomllib.load(fh))   # must not raise


class TestBoundarySub(unittest.TestCase):
    def test_replaces_the_version_in_a_url(self):
        self.assertEqual(
            ab.boundary_sub("https://x/foo-1.0.tar.gz", "1.0", "1.1"),
            "https://x/foo-1.1.tar.gz")

    def test_does_not_touch_a_longer_number_containing_it(self):
        self.assertEqual(
            ab.boundary_sub("https://x/v21.0/foo-1.0.tar", "1.0", "1.1"),
            "https://x/v21.0/foo-1.1.tar")


if __name__ == "__main__":
    unittest.main(verbosity=2)
