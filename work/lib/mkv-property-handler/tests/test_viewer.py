"""Metadata extraction and terminal output tests on the synthetic fixtures."""
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))

import make_test_mkvs  # noqa: E402
import viewer  # noqa: E402

VIEWER = HERE.parent / "viewer.py"
UNICODE_NAME = "영화 テスト ★ with spaces.mkv"
CURRENT = {"tier": "Compact", "crf": "23.5", "video_encoder": "Lavc61.19.101 libx265",
           "video_stream_size": "4.21 GB (4,523,456,789 bytes)",
           "writing_app": "mkvmerge v88.0 ('All I Know') 64-bit",
           "muxing_app": "libebml v1.4.5 + libmatroska v1.7.1"}


def sha256(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


class ViewerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dir = Path(tempfile.mkdtemp(prefix="mkvviewer-"))
        make_test_mkvs.main(str(cls.dir))
        sub = cls.dir / "sub dir ✓"
        sub.mkdir()
        shutil.copyfile(cls.dir / "current_mkvpropedit.mkv", sub / UNICODE_NAME)
        cls.unicode_file = sub / UNICODE_NAME
        cls.small = sorted(p for p in cls.dir.rglob("*.mkv") if p.stat().st_size < 1 << 20)
        cls.hashes = {p: sha256(p) for p in cls.small}
        big = cls.dir / "large_cluster.mkv"
        cls.big_stat = (big.stat().st_size, big.stat().st_mtime_ns)

    @classmethod
    def tearDownClass(cls):
        # files byte-identical after every test (checked here so it runs last)
        changed = [p.name for p in cls.small if sha256(p) != cls.hashes[p]]
        big = cls.dir / "large_cluster.mkv"
        big_same = (big.stat().st_size, big.stat().st_mtime_ns) == cls.big_stat
        shutil.rmtree(cls.dir, ignore_errors=True)
        assert not changed and big_same, f"fixtures modified: {changed or 'large_cluster.mkv'}"

    def read(self, name):
        return viewer.read_compression_info(self.dir / name)

    def assertFields(self, info, **want):
        for k, v in want.items():
            self.assertEqual(getattr(info, k), v, k)

    # --- extraction ---------------------------------------------------------

    def test_current_mkvpropedit_tags(self):
        self.assertFields(self.read("current_mkvpropedit.mkv"), **CURRENT)   # decoys ignored

    def test_old_ffmpeg_tags(self):
        self.assertFields(self.read("old_ffmpeg_tags.mkv"), tier="High", crf="21",
                          video_encoder="Lavc61.19.101 libx265", video_stream_size="")

    def test_crf_only(self):
        self.assertFields(self.read("crf_only.mkv"), crf="18", tier="")

    def test_pre_tagging_output(self):
        self.assertFields(self.read("legacy_no_compression_tags.mkv"), crf="", tier="", video_encoder="Lavc60 libx265")

    def test_no_tags(self):
        i = self.read("no_tags.mkv")
        self.assertTrue(i.is_matroska)
        self.assertFalse(i.tags_found)
        self.assertFields(i, crf="", tier="", video_encoder="")

    def test_no_seekhead_tail_scan(self):
        self.assertFields(self.read("no_seekhead.mkv"), crf="23.5", tier="Compact")

    def test_unknown_segment_size(self):
        self.assertFields(self.read("unknown_segment_size.mkv"), tier="Compact")

    def test_utf8_value(self):
        self.assertFields(self.read("utf8_tier.mkv"), tier="Qualité ★", crf="20")

    def test_truncated(self):
        i = self.read("truncated.mkv")
        self.assertTrue(i.is_matroska)
        self.assertFields(i, crf="", tier="")
        self.assertTrue(i.writing_app)

    def test_huge_tags_size_not_read(self):
        i = self.read("huge_tags_size.mkv")
        self.assertEqual(i.crf, "")
        self.assertLess(i.bytes_read, 4096)

    def test_garbage_and_empty(self):
        for n in ("garbage.mkv", "empty.mkv"):
            i = self.read(n)
            self.assertFalse(i.is_matroska, n)
            self.assertEqual(i.error, "", n)

    def test_large_file_payload_skipped(self):
        i = self.read("large_cluster.mkv")
        self.assertEqual(i.crf, "23.5")
        self.assertLess(i.bytes_read, 4096)   # of 256 MiB

    def test_missing_file_and_directory(self):
        self.assertTrue(viewer.read_compression_info(self.dir / "nope.mkv").error)
        self.assertTrue(viewer.read_compression_info(self.dir).error)

    def test_unicode_path_with_spaces(self):
        self.assertFields(viewer.read_compression_info(self.unicode_file), **CURRENT)

    # --- terminal output -----------------------------------------------------

    def run_viewer(self, *args, stdin=None):
        return subprocess.run([sys.executable, "-I", str(VIEWER), *map(str, args)], capture_output=True,
                              timeout=30, encoding="utf-8", errors="replace",
                              input=stdin, stdin=None if stdin is not None else subprocess.DEVNULL)

    def test_terminal_output_all_fields(self):
        r = self.run_viewer(self.unicode_file)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.splitlines(), [
            f"File: {self.unicode_file}",
            "  Compression tier:    Compact",
            "  Compression CRF:     23.5",
            "  Video encoder:       Lavc61.19.101 libx265",
            "  Video stream size:   4.21 GB (4,523,456,789 bytes)",
            "  Writing application: mkvmerge v88.0 ('All I Know') 64-bit",
            "  Muxing application:  libebml v1.4.5 + libmatroska v1.7.1",
        ])
        self.assertNotIn("Press Enter", r.stdout)   # no pause outside Explorer

    def test_terminal_missing_tags(self):
        r = self.run_viewer(self.dir / "no_tags.mkv", self.dir / "crf_only.mkv")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertRegex(r.stdout, r"Compression tier:\s+Not recorded")
        self.assertRegex(r.stdout, r"Video stream size:\s+Not recorded")
        self.assertRegex(r.stdout, r"Compression CRF:\s+18")
        self.assertIn("\n\nFile: ", r.stdout)   # blank line between files

    def test_exit_codes_and_errors(self):
        r = self.run_viewer(self.dir / "garbage.mkv")
        self.assertEqual(r.returncode, 1)
        self.assertIn("Error: not a Matroska file", r.stdout)
        r = self.run_viewer(self.dir / "truncated.mkv")
        self.assertEqual(r.returncode, 0)   # readable header: partial fields, not an error
        r = self.run_viewer(self.dir / "current_mkvpropedit.mkv", self.dir / "nope.mkv")
        self.assertEqual(r.returncode, 3)
        self.assertIn("Error: cannot open the file", r.stdout)
        self.assertRegex(r.stdout, r"Compression tier:\s+Compact")   # other files still shown
        self.assertEqual(self.run_viewer().returncode, 2)
        self.assertEqual(self.run_viewer("--bogus", self.unicode_file).returncode, 2)

    def test_pause_waits_for_enter(self):
        """--pause (the Explorer entry) ends after Enter, also when stdin is closed."""
        r = self.run_viewer("--pause", self.unicode_file, stdin="\n")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(r.stdout.rstrip().endswith("Press Enter to close..."), r.stdout)
        self.assertRegex(r.stdout, r"Compression CRF:\s+23\.5")
        r = self.run_viewer("--pause", self.dir / "nope.mkv", stdin="")   # EOF: no hang, no traceback
        self.assertEqual((r.returncode, r.stderr), (3, ""))


if __name__ == "__main__":
    unittest.main()
