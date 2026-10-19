"""Batch validation, path collection and the interactive menu."""
import hashlib
import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))

import batch  # noqa: E402
import make_test_mkvs  # noqa: E402
import validate  # noqa: E402

LAUNCHER = HERE.parents[3] / "window_tagger.py"


def run(*args, stdin=None):
    return subprocess.run([sys.executable, "-I", str(LAUNCHER), *map(str, args)], capture_output=True, timeout=60,
                          encoding="utf-8", errors="replace", input=stdin,
                          stdin=None if stdin is not None else subprocess.DEVNULL)


class Feed:
    """Scripted answers for batch.menu / ask; records the prompts."""

    def __init__(self, *answers):
        self.answers, self.prompts = list(answers), []

    def __call__(self, prompt):
        self.prompts.append(prompt)
        if not self.answers:
            raise EOFError
        return self.answers.pop(0)


class BatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="mkvbatch-"))
        cls.lib = cls.tmp / "Library ★ 영화"
        fixtures = cls.lib / "Season 1" / "deep dir"
        make_test_mkvs.main(str(fixtures))
        (fixtures / "large_cluster.mkv").unlink()   # keep the copies below small
        shutil.copyfile(fixtures / "valid_ok.mkv", cls.lib / "Top Level OK.MKV")   # upper-case extension
        (cls.lib / "Season 1" / "clip.mp4").write_bytes(b"not checked")
        (cls.lib / "notes.nfo").write_text("ignored")
        # outside the library, reachable only through a junction / symlink
        cls.outside = cls.tmp / "outside"
        cls.outside.mkdir()
        shutil.copyfile(fixtures / "valid_ok.mkv", cls.outside / "must not be found.mkv")
        cls.junction = subprocess.run(["cmd", "/c", "mklink", "/J", str(cls.lib / "junction"), str(cls.outside)],
                                      capture_output=True).returncode == 0 if os.name == "nt" else False
        try:
            os.symlink(cls.outside, cls.lib / "symlink", target_is_directory=True)
            cls.symlink = True
        except (OSError, NotImplementedError):
            cls.symlink = False   # needs Developer Mode / admin on Windows
        cls.files = sorted(p for p in cls.tmp.rglob("*") if p.is_file() and not p.is_symlink())
        cls.hashes = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in cls.files}

    @classmethod
    def tearDownClass(cls):
        changed = [p.name for p in cls.files if hashlib.sha256(p.read_bytes()).hexdigest() != cls.hashes[p]]
        for link in ("junction", "symlink"):
            p = cls.lib / link
            if os.path.lexists(p):
                os.rmdir(p) if os.name == "nt" else os.unlink(p)   # removes the link, not the target
        shutil.rmtree(cls.tmp, ignore_errors=True)
        assert not changed, f"files modified: {changed}"

    # --- paths ----------------------------------------------------------------

    def test_collect_recursive_without_links(self):
        sel = batch.collect(self.lib)
        names = [p.name for p in sel.mkv]
        self.assertIn("Top Level OK.MKV", names)
        self.assertIn("valid_ok.mkv", names)
        self.assertNotIn("must not be found.mkv", names)
        self.assertEqual([p.name for p in sel.unsupported], ["clip.mp4"])
        links = {p.name for p in sel.links}
        if self.junction:
            self.assertIn("junction", links)
        if self.symlink:
            self.assertIn("symlink", links)
        if not (self.junction or self.symlink):
            self.skipTest("could not create a junction or symlink here")

    def test_collect_single_files(self):
        self.assertEqual(len(batch.collect(self.lib / "Top Level OK.MKV").mkv), 1)
        sel = batch.collect(self.lib / "Season 1" / "clip.mp4")
        self.assertEqual((len(sel.mkv), len(sel.unsupported)), (0, 1))

    def test_clean_path(self):
        p = str(self.lib)
        for typed in (p, f'"{p}"', f"'{p}'", f"  {p}  ", f"& '{p}'"):
            self.assertEqual(batch.clean_path(typed), p, typed)

    # --- validation -------------------------------------------------------------

    def test_validation_batch_continues_and_summarises(self):
        out = []
        status = batch.run_validation(batch.collect(self.lib), titles=False, out=out.append)
        text = "\n".join(out)
        self.assertEqual(status, 3)   # garbage / empty / clip.mp4 in the batch
        self.assertIn("Top Level OK.MKV", text)
        self.assertRegex(text, r"Invalid MKV:\s+2")          # garbage.mkv, empty.mkv: batch went on
        self.assertRegex(text, r"Unsupported \(not MKV\):\s+1")
        self.assertIn("UNSUPPORTED  Season 1\\clip.mp4" if os.name == "nt" else "UNSUPPORTED  Season 1/clip.mp4", text)
        self.assertRegex(text, r"OK:\s+4\b")                  # valid_ok.mkv, its copy, provenance_current / _unknown
        self.assertIn("read-only: no file was modified", text)

    def expect(self, name, kind, words):
        r = validate.validate_file(self.lib / "Season 1" / "deep dir" / name)
        hits = [f for f in r.findings if f.kind == kind and words in str(f)]
        self.assertTrue(hits, f"{name}: no {kind} '{words}' in {[str(f) for f in r.findings]}")
        return r

    def test_findings(self):
        self.assertEqual(validate.validate_file(self.lib / "Top Level OK.MKV").status, "OK")
        self.expect("crf_mismatch.mkv", "INCONSISTENT", "x265 crf=20.0")
        self.expect("x265_untagged.mkv", "OUTDATED", "x265 CRF 24.0")
        self.expect("twopass_with_crf.mkv", "INCONSISTENT", "not a CRF encode")
        self.expect("stats_outdated.mkv", "OUTDATED", "before the file was last muxed")
        self.expect("conflicting_tags.mkv", "INCONSISTENT", "2 global values")
        self.expect("bad_values.mkv", "INVALID", "'twenty' is not a number")
        self.expect("bad_values.mkv", "INVALID", "'Ultra' is not a tier name")
        self.expect("bad_values.mkv", "MISSING", "no title")
        self.expect("tier_without_crf.mkv", "INCONSISTENT", "without COMPRESSION_CRF")
        self.expect("current_mkvpropedit.mkv", "INVALID", "targets a track / chapter")
        self.expect("truncated.mkv", "INVALID", "truncated")
        self.expect("no_tags.mkv", "MISSING", "Statistics tags")
        self.assertEqual(validate.validate_file(self.lib / "Season 1" / "deep dir" / "garbage.mkv").status, "INVALID")
        self.assertEqual(validate.validate_file(self.lib / "nope.mkv").status, "UNREADABLE")

    def test_provenance_findings(self):
        d = self.lib / "Season 1" / "deep dir"
        r = validate.validate_file(d / "provenance_current.mkv")
        self.assertEqual(r.status, "OK", [str(f) for f in r.findings])
        lines = dict(r.lines)
        self.assertEqual((lines["Compression tool"], lines["Compressor version"], lines["Compression date"],
                          lines["Compression tier"], lines["Compression CRF"]),
                         ("movie-compresser", "v1.4.2-5-ga3f8c21-dirty", "2026-10-19", "Base", "23"))
        self.assertIn("Compressor version:   v1.4.2-5-ga3f8c21-dirty", "\n".join(validate.format_report(r)))
        self.expect("provenance_current.mkv", "INFO", "uncommitted changes (-dirty)")
        self.expect("provenance_conflict.mkv", "INCONSISTENT", "MOVIE_COMPRESSER_VERSION: 2 global values")
        self.expect("provenance_ffmpeg_version.mkv", "INVALID", "looks like an FFmpeg / x265 / MKVToolNix version")
        self.expect("provenance_partial.mkv", "INCONSISTENT", "COMPRESSION_TOOL missing")
        self.expect("provenance_partial.mkv", "INVALID", "'19/10/2026' is not an ISO 8601 date")
        self.expect("provenance_on_track.mkv", "INVALID", "MOVIE_COMPRESSER_VERSION: 'v9.9.9' targets a track")
        r = self.expect("provenance_unknown.mkv", "INFO", "recorded as 'unknown'")
        self.assertEqual(r.status, "OK")

    def test_historical_file_without_provenance_is_not_a_problem(self):
        r = self.expect("valid_ok.mkv", "INFO", "Compressor version: Not recorded")
        self.assertEqual(r.status, "OK")
        lines = dict(r.lines)
        for label in ("Compression tool", "Compressor version", "Compression date"):
            self.assertEqual(lines[label], "Not recorded", label)
        # the x265 version is shown as the encoder's, never as the compressor version
        self.assertIn("x265 4.1+1-1d117be", lines["Video encode"])

    def test_view_recursive_shows_provenance(self):
        r = run("view", self.lib)
        self.assertRegex(r.stdout, r"provenance_current\.mkv\n  Compression tool:\s+movie-compresser\n"
                                   r"  Compressor version:\s+v1\.4\.2-5-ga3f8c21-dirty\n  Compression date:\s+2026-10-19")
        self.assertRegex(r.stdout, r"valid_ok\.mkv\n  Compression tool:\s+Not recorded\n  Compressor version:\s+Not recorded")

    def test_tier_names_from_encode_common(self):
        self.assertEqual(set(validate.tier_names()), {"Quality", "High", "Base", "Compact", "Custom"})

    def test_verify_titles_bridge_loads_check_track_titles(self):
        bash, why = validate.title_checker()
        if not bash:
            self.skipTest(why)
        p = subprocess.run([bash, str(validate.TITLES_SCRIPT), str(self.lib / "Top Level OK.MKV")],
                           capture_output=True, timeout=60, encoding="utf-8", errors="replace")
        # the synthetic file has no decodable video for ffprobe: the script gets past
        # loading verify.sh's function and stops at the stream check, writing nothing
        self.assertNotIn("not found in verify.sh", p.stdout)
        self.assertIn("ERROR\tno video stream", p.stdout)

    # --- CLI --------------------------------------------------------------------

    def test_validate_command_exit_codes(self):
        ok = run("validate", "--no-titles", self.lib / "Top Level OK.MKV")
        self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)
        issues = run("validate", "--no-titles", self.lib / "Season 1" / "deep dir" / "crf_mismatch.mkv")
        self.assertEqual(issues.returncode, 1)
        self.assertEqual(run("validate", self.tmp / "missing dir").returncode, 3)

    def test_view_accepts_a_directory(self):
        r = run("view", self.lib / "Season 1")
        self.assertIn("valid_ok.mkv", r.stdout)
        self.assertIn("Error: not a Matroska file", r.stdout)
        self.assertEqual(r.returncode, 1)

    # --- interactive menu -------------------------------------------------------

    def test_menu_validate_via_stdin(self):
        r = run(stdin=f"1\n\"{self.lib / 'Season 1' / 'deep dir'}\"\nn\n3\n")
        self.assertEqual(r.returncode, 0, r.stderr)
        for text in ("MKV Metadata Manager", "1) Validate MKV metadata", "2) Windows metadata integration",
                     "3) Exit", "Select [1-3]:", "Enter MKV file or directory path:", "> ",
                     "Summary (read-only: no file was modified)"):
            self.assertIn(text, r.stdout)

    def test_menu_invalid_choice_missing_path_and_eof(self):
        out, feed = [], Feed("9", "1", str(self.tmp / "nope"), "", "")
        self.assertEqual(batch.menu(ask=feed, out=out.append), 0)   # ends at EOF
        text = "\n".join(out)
        self.assertIn("Invalid selection.", text)
        self.assertIn("Not found:", text)

    def test_menu_integration_leaves_installed_entry(self):
        import installer
        state = installer.State(present=True, ours=True, kind="python", command="x")
        out, feed = [], Feed("2", str(self.lib / "Top Level OK.MKV"), "3")
        with mock.patch.object(installer, "get_state", return_value=state), \
                mock.patch.object(installer, "install") as inst:
            batch.menu(ask=feed, out=out.append)
        text = "\n".join(out)
        inst.assert_not_called()
        self.assertIn("installed - left unchanged", text)
        self.assertRegex(text, r"Compression tier:\s+Base")
        self.assertIn("Properties > Details: not available", text)
        self.assertFalse(any("[y/N]" in p for p in feed.prompts))

    def test_menu_integration_offers_update_of_outdated_viewer_copy(self):
        """An entry installed by an earlier version runs an old viewer.py copy
        (without the compressor version fields): reported and offered, never
        changed without a yes."""
        import installer
        state = installer.State(present=True, ours=True, kind="python", command="x", viewer_present=True,
                                viewer_outdated=True)
        for answer, installs in (("n", False), ("y", True)):
            out, feed = [], Feed("2", str(self.lib / "Top Level OK.MKV"), answer, "3")
            with mock.patch.object(installer, "get_state", return_value=state), \
                    mock.patch.object(installer, "install") as inst:
                batch.menu(ask=feed, out=out.append)
            self.assertEqual(inst.called, installs, answer)
            self.assertIn("its viewer copy is older", "\n".join(out))

    def test_menu_integration_offers_install_when_missing(self):
        import installer
        for answer, installs in (("n", False), ("y", True)):
            out, feed = [], Feed("2", str(self.lib), answer, "3")
            with mock.patch.object(installer, "get_state", return_value=installer.State()), \
                    mock.patch.object(installer, "install") as inst:
                with redirect_stdout(io.StringIO()):
                    batch.menu(ask=feed, out=out.append)
            self.assertEqual(inst.called, installs, answer)
            self.assertIn("not installed", "\n".join(out))


if __name__ == "__main__":
    unittest.main()
