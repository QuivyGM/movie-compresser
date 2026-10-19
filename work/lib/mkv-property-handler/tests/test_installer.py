"""Install / uninstall / migration tests (Windows).

Most run against a sandbox key, HKCU\\Software\\movie-compresser-tests\\<pid>,
and a temporary viewer directory. One round trip uses the real per-user
location, only when no "Compression info" entry is installed there yet.
HKLM is only read, to check it never changes.
"""
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

if sys.platform != "win32":
    raise unittest.SkipTest("Windows only")

import winreg  # noqa: E402

import installer  # noqa: E402
import make_test_mkvs  # noqa: E402

SANDBOX = rf"Software\movie-compresser-tests\{os.getpid()}"
HKLM_WATCH = [(r"SOFTWARE\Microsoft\Windows\CurrentVersion\PropertySystem\PropertyHandlers\.mkv", ""),
              (r"SOFTWARE\Classes\SystemFileAssociations\.mkv", "FullDetails"),
              (r"SOFTWARE\Microsoft\Windows\CurrentVersion\PropertySystem\SystemPropertyHandlers", ".mkv")]


def hklm_snapshot():
    out = []
    for path, name in HKLM_WATCH:
        try:
            with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, path, 0, winreg.KEY_READ | winreg.KEY_WOW64_64KEY) as k:
                out.append(winreg.QueryValueEx(k, name)[0])
        except FileNotFoundError:
            out.append(None)
    out.append(installer.legacy_native_leftovers())
    return out


def key_exists(path):
    try:
        winreg.OpenKey(winreg.HKEY_CURRENT_USER, path).Close()
        return True
    except FileNotFoundError:
        return False


def write_key(path, values):
    with winreg.CreateKeyEx(winreg.HKEY_CURRENT_USER, path, 0, winreg.KEY_WRITE) as k:
        for name, (kind, v) in values.items():
            winreg.SetValueEx(k, name, 0, kind, v)


def run_command(cmd, file):
    """Runs a registered verb command for file as Explorer would (%1 = the
    quoted path), answering the "Press Enter" prompt."""
    return subprocess.run(cmd.replace("%1", str(file)), capture_output=True, timeout=30, input="\n",
                          encoding="utf-8", errors="replace")


class InstallerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.hklm_before = hklm_snapshot()
        cls.fixtures = Path(tempfile.mkdtemp(prefix="mkvinst-fx-"))
        make_test_mkvs.main(str(cls.fixtures))
        cls.mkv = cls.fixtures / "with space ★.mkv"
        shutil.copyfile(cls.fixtures / "current_mkvpropedit.mkv", cls.mkv)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.fixtures, ignore_errors=True)

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="mkvinst-"))
        self.cfg = installer.Config(assoc=rf"{SANDBOX}\Classes\SystemFileAssociations\.mkv",
                                    viewer_dir=self.tmp / "local app data" / "movie-compresser" / "MkvTagViewer")
        self.log = []

    def tearDown(self):
        installer._delete_tree(self.cfg, SANDBOX)
        try:
            winreg.DeleteKey(winreg.HKEY_CURRENT_USER, r"Software\movie-compresser-tests")
        except OSError:
            pass   # another run's sandbox is still there
        shutil.rmtree(self.tmp, ignore_errors=True)
        self.assertEqual(hklm_snapshot(), self.hklm_before, "HKLM changed")

    def install(self, **kw):
        installer.install(self.cfg, log=self.log.append, **kw)

    def uninstall(self, **kw):
        installer.uninstall(self.cfg, log=self.log.append, **kw)

    def test_install_and_uninstall(self):
        self.install()
        s = installer.get_state(self.cfg)
        self.assertEqual((s.kind, s.ours, s.broken), ("python", True, False))
        self.assertEqual(s.command, installer.command_line(self.cfg))
        self.assertEqual((self.cfg.viewer_dir / "viewer.py").read_bytes(), installer.VIEWER_SOURCE.read_bytes())
        self.assertTrue(installer._split_command(s.command).lower().endswith("python.exe"), s.command)
        self.assertIn(" --pause ", s.command)
        r = run_command(s.command, self.mkv)   # the exact registered command line
        self.assertEqual((r.returncode, r.stderr), (0, ""))
        self.assertIn(f"File: {self.mkv}", r.stdout)
        self.assertRegex(r.stdout, r"Compression tier:\s+Compact")
        self.assertTrue(r.stdout.rstrip().endswith("Press Enter to close..."))
        self.assertFalse(s.viewer_outdated)
        (self.cfg.viewer_dir / "viewer.py").write_bytes(b"# viewer.py of an earlier version\n")
        self.assertTrue(installer.get_state(self.cfg).viewer_outdated)
        self.install()   # reinstall: same result, no duplicates, copy refreshed
        self.assertEqual(installer.get_state(self.cfg).command, s.command)
        self.assertFalse(installer.get_state(self.cfg).viewer_outdated)
        self.uninstall()
        s = installer.get_state(self.cfg)
        self.assertFalse(s.present or s.viewer_present)
        self.assertFalse(self.cfg.viewer_dir.exists() or self.cfg.viewer_dir.parent.exists())
        self.assertFalse(key_exists(self.cfg.assoc), "created parent keys left behind")

    def test_existing_parents_and_other_verbs_kept(self):
        write_key(rf"{self.cfg.assoc}\shell\Other", {"MUIVerb": (winreg.REG_SZ, "someone else")})
        self.install()
        self.uninstall()
        self.assertTrue(key_exists(rf"{self.cfg.assoc}\shell\Other"))
        self.assertFalse(key_exists(self.cfg.verb_key))

    def test_foreign_verb_refused_and_kept(self):
        write_key(self.cfg.verb_key, {"MUIVerb": (winreg.REG_SZ, "someone else")})
        with self.assertRaises(installer.Refused):
            self.install()
        self.uninstall()
        s = installer.get_state(self.cfg)
        self.assertEqual((s.present, s.kind), (True, "foreign"))
        self.assertFalse(self.cfg.viewer_dir.exists())

    def make_powershell_install(self, with_files=True):
        """What window_tagger.ps1 install left: same key and marker, mkvtagsw.exe."""
        self.cfg.viewer_dir.mkdir(parents=True)
        exe = self.cfg.viewer_dir / "mkvtagsw.exe"
        if with_files:
            for n in installer.LEGACY_FILES:
                (self.cfg.viewer_dir / n).write_bytes(b"MZ old")
        write_key(self.cfg.verb_key, {"MUIVerb": (winreg.REG_SZ, "Compression info"),
                                      "Icon": (winreg.REG_SZ, f"{exe},0"),
                                      installer.MARKER: (winreg.REG_DWORD, 1)})
        write_key(self.cfg.verb_key + r"\command", {"": (winreg.REG_SZ, f'"{exe}" --gui "%1"')})

    def test_migration_from_powershell(self):
        self.make_powershell_install()
        s = installer.get_state(self.cfg)
        self.assertEqual((s.kind, s.broken), ("legacy-powershell", False))
        self.install()
        s = installer.get_state(self.cfg)
        self.assertEqual((s.kind, s.broken, s.legacy_files), ("python", False, []))
        r = run_command(s.command, self.mkv)
        self.assertEqual((r.returncode, r.stderr), (0, ""))
        self.uninstall()
        self.assertFalse(installer.get_state(self.cfg).present)

    def test_broken_powershell_entry_removed(self):
        self.make_powershell_install(with_files=False)   # programs already deleted
        self.assertTrue(installer.get_state(self.cfg).broken)
        self.uninstall()
        s = installer.get_state(self.cfg)
        self.assertFalse(s.present)
        self.assertTrue(key_exists(self.cfg.assoc), "pre-existing parents must stay (not recorded as ours)")

    def test_dry_runs_change_nothing(self):
        self.install(dry_run=True)
        self.assertFalse(installer.get_state(self.cfg).present or self.cfg.viewer_dir.exists())
        self.install()
        self.uninstall(dry_run=True)
        self.assertEqual(installer.get_state(self.cfg).kind, "python")
        self.uninstall()

    def test_real_per_user_round_trip(self):
        real = installer.Config()
        if installer.get_state(real).present or real.viewer_dir.exists():
            self.skipTest("Compression info already installed for this user: left as is")
        try:
            installer.install(real, log=self.log.append)
            s = installer.get_state(real)
            self.assertEqual((s.kind, s.broken), ("python", False))
            r = run_command(s.command, self.mkv)
            self.assertEqual((r.returncode, r.stderr), (0, ""))
        finally:
            installer.uninstall(real, log=self.log.append)
        s = installer.get_state(real)
        self.assertFalse(s.present or real.viewer_dir.exists())


class LauncherTests(unittest.TestCase):
    def test_status_and_view(self):
        launcher = HERE.parents[3] / "window_tagger.py"
        r = subprocess.run([sys.executable, "-I", str(launcher), "status"], capture_output=True, timeout=30,
                           encoding="utf-8", errors="replace")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("Compression info", r.stdout)
        with tempfile.TemporaryDirectory(prefix="mkvlaunch-") as d:
            make_test_mkvs.main(d)
            f = Path(d) / "파일 이름 with spaces.mkv"
            shutil.copyfile(Path(d) / "old_ffmpeg_tags.mkv", f)
            r = subprocess.run([sys.executable, "-I", str(launcher), "view", str(f)], capture_output=True,
                               timeout=30, encoding="utf-8", errors="replace")
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertRegex(r.stdout, r"Compression tier:\s+High")


if __name__ == "__main__":
    unittest.main()
