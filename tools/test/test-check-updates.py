#!/usr/bin/env python3
"""Unit tests for check-updates.py's pure logic — no network.

Everything here is version-string handling and recipe→provider detection, which
is where the freshness report actually gets things wrong: a tag shape nobody
anticipated silently becomes "no usable tags", and a package stops being
tracked. Run: python3 tools/test/test-check-updates.py
"""
import importlib.util
import os
import sys
import unittest
import unittest.mock

TOP = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_spec = importlib.util.spec_from_file_location(
    "check_updates", os.path.join(TOP, "tools", "pkg", "check-updates.py"))
cu = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cu)


class TestNewer(unittest.TestCase):
    def test_numeric_components_compare_as_numbers(self):
        self.assertTrue(cu.newer("1.10.0", "1.9.0"))
        self.assertFalse(cu.newer("1.9.0", "1.10.0"))

    def test_release_outranks_prerelease(self):
        self.assertTrue(cu.newer("1.0", "1.0rc1"))
        self.assertFalse(cu.newer("1.0rc1", "1.0"))

    def test_letter_suffix_is_a_later_patch_not_a_prerelease(self):
        # tmux ships 3.7a/3.7b after 3.7; only the rc/alpha/beta words demote.
        self.assertTrue(cu.newer("3.7b", "3.7"))
        self.assertFalse(cu.newer("3.7", "3.7b"))
        self.assertTrue(cu.newer("3.7b", "3.7a"))

    def test_longer_wins_when_prefix_equal(self):
        self.assertTrue(cu.newer("1.2.3", "1.2"))
        self.assertFalse(cu.newer("1.2", "1.2.3"))


class TestClean(unittest.TestCase):
    def test_v_prefix(self):
        self.assertEqual(cu._clean("v1.2.3"), "1.2.3")

    def test_project_name_prefix(self):
        # the shapes real repos actually tag with
        self.assertEqual(cu._clean("openssl-3.4.6"), "3.4.6")
        self.assertEqual(cu._clean("pcre2-10.47"), "10.47")
        self.assertEqual(cu._clean("jq-1.7.1"), "1.7.1")
        self.assertEqual(cu._clean("fuse-3.18.2"), "3.18.2")
        self.assertEqual(cu._clean("llvmorg-22.1.8"), "22.1.8")
        self.assertEqual(cu._clean("go1.26.5"), "1.26.5")
        self.assertEqual(cu._clean("r58"), "58")

    def test_underscore_separated(self):
        self.assertEqual(cu._clean("R_2_8_2"), "2.8.2")          # libexpat
        self.assertEqual(cu._clean("libnl3_11_0"), "3.11.0")     # libnl
        self.assertEqual(cu._clean("RELEASE_7_4"), "7.4")        # smartmontools
        self.assertEqual(cu._clean("NSS_3_108_RTM"), "3.108")    # nss

    def test_hyphen_joined_version_components(self):
        # flex tags flex-2-5-10 and logrotate r3-9-1: the leading digit is the
        # major version, not a name suffix like pcre2's.
        self.assertEqual(cu._clean("flex-2-5-10"), "2.5.10")
        self.assertEqual(cu._clean("r3-9-1"), "3.9.1")
        self.assertEqual(cu._pick_latest(["v2.6.4", "flex-2-5-10"], "2.6.4"), "2.6.4")

    def test_repeated_name_segments_are_stripped(self):
        self.assertEqual(cu._clean("json-c-0.19-20250808"), "0.19.20250808")

    def test_refs_and_namespaces_are_dropped(self):
        self.assertEqual(cu._clean("refs/tags/v2.1.0"), "2.1.0")

    def test_hyphen_between_digits_is_a_separator_not_a_name(self):
        # libedit ships 20240808-3.1 (a date plus a version); the recipe writes
        # it 20240808_3.1, and both must compare equal.
        self.assertEqual(cu._clean("libedit-20240808-3.1"), "20240808.3.1")
        self.assertFalse(cu.newer("20240808.3.1", "20240808_3.1"))
        self.assertFalse(cu.newer("20240808_3.1", "20240808.3.1"))

    def test_portable_release_suffix_kept(self):
        self.assertEqual(cu._clean("openssh-10.3p1"), "10.3p1")
        self.assertTrue(cu.newer("10.3p2", "10.3p1"))

    def test_plain_version_untouched(self):
        self.assertEqual(cu._clean("14.1.1"), "14.1.1")
        self.assertEqual(cu._clean("2026.05.30"), "2026.05.30")


class TestPickLatest(unittest.TestCase):
    def test_picks_highest(self):
        self.assertEqual(cu._pick_latest(["1.2.0", "1.10.0", "1.9.0"], "1.2.0"), "1.10.0")

    def test_skips_prereleases(self):
        self.assertEqual(cu._pick_latest(["2.0.0", "2.1.0-rc1"], "1.9.0"), "2.0.0")

    def test_skips_date_serials_for_dotted_projects(self):
        self.assertEqual(cu._pick_latest(["1.2.3", "20260601"], "1.2.0"), "1.2.3")

    def test_track_constrains_to_a_release_series(self):
        cands = ["3.4.6", "3.4.7", "3.7.1"]
        self.assertEqual(cu._pick_latest(cands, "3.4.6", track="3.4"), "3.4.7")
        self.assertEqual(cu._pick_latest(cands, "3.4.6"), "3.7.1")

    def test_track_matches_series_prefix_not_substring(self):
        # "3.4" must not swallow 3.40.x
        self.assertEqual(cu._pick_latest(["3.4.9", "3.40.1"], "3.4.1", track="3.4"), "3.4.9")

    def test_none_when_nothing_usable(self):
        self.assertIsNone(cu._pick_latest(["nightly", "tip"], "1.0"))

    def test_platform_tags_are_not_versions(self):
        # smartmontools tags X86_64_LINUX_OK next to RELEASE_7_5; parsing the
        # arch as version 86.64 would report a permanent bogus update.
        self.assertEqual(
            cu._pick_latest(["X86_64_LINUX_OK", "WINDOWS_OK", "RELEASE_7_5",
                             "RELEASE_7_4"], "7.4"),
            "7.5")

    def test_word_salad_tags_are_rejected(self):
        self.assertIsNone(cu._pick_latest(
            ["ROOT_OF_RELEASE_5_33_WITH_MARVELL_SUPPORT", "start"], "7.4"))


def _recipe(url, upstream=None):
    r = {"package": {"name": "x", "version": "1.0"}, "source": [{"url": url}]}
    if upstream:
        r["upstream"] = upstream
    return r


class TestDetect(unittest.TestCase):
    def test_explicit_overrides_win(self):
        self.assertEqual(cu.detect(_recipe("https://x/y-1.0.tar.gz", {"github": "o/r"})),
                         ("github", "o/r"))
        self.assertEqual(
            cu.detect(_recipe("https://x/y-1.0.tar.gz",
                              {"url": "https://x/", "regex": "y-(1.0)", "join": "."})),
            ("regex", ("https://x/", "y-(1.0)", ".")))
        self.assertEqual(cu.detect(_recipe("https://x/y-1.0.tar.gz", {"pypi": "jinja2"})),
                         ("pypi", "jinja2"))
        self.assertEqual(cu.detect(_recipe("https://x/y-1.0.tar.gz",
                                           {"sourceforge": "gptfdisk"})),
                         ("sourceforge", "gptfdisk"))

    def test_skip(self):
        method, note = cu.detect(_recipe("https://x/y-1.0.tar.gz",
                                         {"skip": True, "reason": "first-party"}))
        self.assertEqual(method, "skip")
        self.assertEqual(note, "first-party")

    def test_github_and_gnu_still_detected(self):
        self.assertEqual(
            cu.detect(_recipe("https://github.com/o/r/archive/1.0/r-1.0.tar.gz")),
            ("github", "o/r"))
        self.assertEqual(
            cu.detect(_recipe("https://ftp.gnu.org/gnu/tar/tar-1.35.tar.xz")),
            ("gnu", "tar"))

    def test_sourceforge_auto_detected(self):
        for url in ("https://downloads.sourceforge.net/gptfdisk/gptfdisk-1.0.10.tar.gz",
                    "https://download.sourceforge.net/gptfdisk/gptfdisk-1.0.10.tar.gz",
                    "https://downloads.sourceforge.net/project/gptfdisk/gptfdisk-1.0.10.tar.gz"):
            self.assertEqual(cu.detect(_recipe(url)), ("sourceforge", "gptfdisk"), url)

    def test_listing_fallback_uses_parent_directory(self):
        method, arg = cu.detect(_recipe(
            "https://www.kernel.org/pub/linux/utils/kmod/kmod-33.tar.xz"))
        self.assertEqual(method, "listing")
        self.assertEqual(arg, ("https://www.kernel.org/pub/linux/utils/kmod/", "kmod"))

    def test_listing_handles_renamed_sources(self):
        method, arg = cu.detect(_recipe(
            "krb5-1.22.2.tar.gz::https://kerberos.org/dist/krb5/1.22/krb5-1.22.2.tar.gz"))
        self.assertEqual(method, "listing")
        self.assertEqual(arg, ("https://kerberos.org/dist/krb5/1.22/", "krb5"))

    def test_no_source_is_untracked(self):
        self.assertEqual(cu.detect({"package": {"name": "bpm"}}), (None, None))

    def test_non_tarball_source_is_untracked(self):
        self.assertEqual(cu.detect(_recipe("https://curl.se/ca/cacert-2026-05-14.pem")),
                         (None, None))


class TestRegexProvider(unittest.TestCase):
    def test_multiple_groups_are_joined(self):
        """A date version the recipe writes without separators (ca-certificates
        ships 20260514) has to be reassembled from the page's 2026-05-14."""
        html = 'cacert-2026-01-09.pem cacert-2026-05-14.pem'
        with unittest.mock.patch.object(cu, "_get", lambda *a, **k: html):
            self.assertEqual(
                cu.latest_regex(("https://x", r"cacert-(\d{4})-(\d{2})-(\d{2})\.pem", ""),
                                "20260109"),
                "20260514")

    def test_join_puts_the_separator_back(self):
        """A page that prints the version differently than the recipe writes it
        (2_4_1 vs 2.4.1) is reassembled with the recipe's separator. Zero
        padding survives the join but is numerically equal (3.53.04 == 3.53.4),
        which is what sqlite's 3530400 encoding needs."""
        html = "foo_2_4_0.tar foo_2_4_1.tar"
        with unittest.mock.patch.object(cu, "_get", lambda *a, **k: html):
            self.assertEqual(
                cu.latest_regex(("https://x", r"foo_(\d)_(\d)_(\d)\.tar", "."), "2.4.0"),
                "2.4.1")
        self.assertFalse(cu.newer("3.53.04", "3.53.4"))
        self.assertTrue(cu.newer("3.53.04", "3.53.3"))


class TestListingRegex(unittest.TestCase):
    def test_extracts_versions_from_an_apache_index(self):
        html = ('<a href="kmod-32.tar.xz">kmod-32.tar.xz</a>'
                '<a href="kmod-33.tar.xz">kmod-33.tar.xz</a>'
                '<a href="kmod-33.tar.sign">sig</a>')
        self.assertEqual(sorted(set(cu._listing_versions(html, "kmod"))), ["32", "33"])

    def test_ignores_other_projects_in_the_same_index(self):
        html = '<a href="libcap-2.73.tar.xz">x</a><a href="libcap-ng-0.8.5.tar.gz">y</a>'
        self.assertEqual(cu._listing_versions(html, "libcap"), ["2.73"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
