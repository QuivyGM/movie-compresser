"""Per-user Explorer integration of the read-only viewer (Windows, winreg).

Install adds one context menu verb, "Compression info", for .mkv files:

    HKCU\\Software\\Classes\\SystemFileAssociations\\.mkv\\shell\\MovieCompresser.CompressionInfo
        MUIVerb  = Compression info
        Icon     = python.exe,0
        MovieCompresserViewer = 1          (ownership marker)
        CreatedKeys = parent keys this install created (removed when empty)
        command\\(default) = "python.exe" -I "%LOCALAPPDATA%\\movie-compresser\\MkvTagViewer\\viewer.py" --pause "%1"

Explorer opens a console window for python.exe; viewer.py prints the fields
there and, because of --pause, waits for Enter before the window closes.

viewer.py is copied there first, so the verb never points at a missing
file. No administrator rights, no HKLM change, no property handler: Windows
pins .mkv to its own property handler (SystemPropertyHandlers), which is
left alone. Uninstall removes only what carries the ownership marker.

An entry left by the earlier PowerShell version (same key and marker,
command running mkvtagsw.exe) is replaced on install and removed on
uninstall, together with its mkvtagsw.exe / mkvtags.exe.
"""
import os
import shutil
import sys
import winreg
from dataclasses import dataclass, field
from pathlib import Path

VERB = "MovieCompresser.CompressionInfo"
MARKER = "MovieCompresserViewer"
LEGACY_FILES = ("mkvtagsw.exe", "mkvtags.exe")   # PowerShell version
VIEWER_SOURCE = Path(__file__).with_name("viewer.py")

# read-only checks of what the older native-handler experiment may have left (HKLM)
LEGACY_NATIVE_KEYS = (r"SOFTWARE\movie-compresser\MkvPropertyHandler",
                      r"SOFTWARE\Classes\CLSID\{2E8983D5-82EF-421F-9489-3E2AAA20DF15}")
PIN_KEY = r"SOFTWARE\Microsoft\Windows\CurrentVersion\PropertySystem\SystemPropertyHandlers"


class Refused(Exception):
    """An install / uninstall step that would touch something not ours."""


@dataclass
class Config:
    hive: int = winreg.HKEY_CURRENT_USER
    assoc: str = r"Software\Classes\SystemFileAssociations\.mkv"
    viewer_dir: Path = field(default_factory=lambda: Path(os.environ["LOCALAPPDATA"]) / "movie-compresser" / "MkvTagViewer")

    @property
    def verb_key(self):
        return rf"{self.assoc}\shell\{VERB}"


@dataclass
class State:
    present: bool = False
    ours: bool = False
    command: str = ""
    kind: str = "none"        # none | python | legacy-powershell | foreign
    target: str = ""          # program the command runs
    broken: bool = False      # ours, but its program or viewer.py is missing
    viewer_present: bool = False
    legacy_files: list = field(default_factory=list)


def console_python():
    """Console interpreter of this Python (python.exe, not pythonw.exe):
    Explorer opens a console window for it, where the fields are printed."""
    base = Path(getattr(sys, "_base_executable", sys.executable))   # outside any venv
    for cand in (base, Path(sys.executable)):
        exe = cand.with_name("python.exe") if cand.name.lower() == "pythonw.exe" else cand
        if exe.exists():
            return exe
    return Path(sys.executable)


def command_line(cfg):
    return f'"{console_python()}" -I "{cfg.viewer_dir / "viewer.py"}" --pause "%1"'


# --- registry helpers -------------------------------------------------------

def _open(cfg, path, access=winreg.KEY_READ):
    try:
        return winreg.OpenKey(cfg.hive, path, 0, access)
    except FileNotFoundError:
        return None


def _value(key, name, default=None):
    try:
        return winreg.QueryValueEx(key, name)[0]
    except FileNotFoundError:
        return default


def _exists(cfg, path):
    k = _open(cfg, path)
    if k:
        k.Close()
    return k is not None


def _delete_tree(cfg, path):
    k = _open(cfg, path, winreg.KEY_READ | winreg.KEY_WRITE)
    if not k:
        return
    with k:
        while True:
            try:
                sub = winreg.EnumKey(k, 0)
            except OSError:
                break
            _delete_tree(cfg, rf"{path}\{sub}")
    winreg.DeleteKey(cfg.hive, path)


def _is_empty(cfg, path):
    k = _open(cfg, path)
    if not k:
        return False
    with k:
        subkeys, values, _ = winreg.QueryInfoKey(k)
    return subkeys == 0 and values == 0


def _split_command(cmd):
    """First (quoted) token of a command line."""
    cmd = cmd.strip()
    if cmd.startswith('"'):
        return cmd[1:].split('"', 1)[0]
    return cmd.split(" ", 1)[0]


# --- state ------------------------------------------------------------------

def get_state(cfg=None):
    cfg = cfg or Config()
    s = State(viewer_present=(cfg.viewer_dir / "viewer.py").exists(),
              legacy_files=[n for n in LEGACY_FILES if (cfg.viewer_dir / n).exists()])
    k = _open(cfg, cfg.verb_key)
    if not k:
        return s
    with k:
        s.present = True
        s.ours = bool(_value(k, MARKER, 0))
    c = _open(cfg, cfg.verb_key + r"\command")
    if c:
        with c:
            s.command = _value(c, "", "") or ""
    s.target = _split_command(s.command) if s.command else ""
    if not s.ours:
        s.kind = "foreign"
    elif s.target.lower().endswith("mkvtagsw.exe"):
        s.kind = "legacy-powershell"
    else:
        s.kind = "python"
    if s.ours:
        missing_target = not s.target or not Path(s.target).exists()
        s.broken = missing_target or (s.kind == "python" and not s.viewer_present)
    return s


def _hklm_exists(path):
    try:
        winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, path, 0, winreg.KEY_READ | winreg.KEY_WOW64_64KEY).Close()
        return True
    except FileNotFoundError:
        return False


def legacy_native_leftovers():
    """HKLM keys of the old native property-handler install, if any (read-only)."""
    return [p for p in LEGACY_NATIVE_KEYS if _hklm_exists(p)]


def system_pin():
    """CLSID Windows pins .mkv to (SystemPropertyHandlers), or ''."""
    try:
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, PIN_KEY, 0, winreg.KEY_READ | winreg.KEY_WOW64_64KEY) as k:
            return _value(k, ".mkv", "") or ""
    except FileNotFoundError:
        return ""


def _notify_shell():
    try:
        import ctypes
        ctypes.windll.shell32.SHChangeNotify(0x08000000, 0, None, None)   # SHCNE_ASSOCCHANGED
    except (AttributeError, OSError):
        pass


# --- install / uninstall ----------------------------------------------------

def install(cfg=None, dry_run=False, log=print):
    cfg = cfg or Config()
    s = get_state(cfg)
    if s.present and not s.ours:
        raise Refused(f"HKCU\\{cfg.verb_key} exists and was not created by this tool "
                      f"(command: {s.command or '-'}); leaving it alone.")
    prefix = "[dry run] " if dry_run else ""
    if s.kind == "legacy-powershell":
        log(f"{prefix}migrate the PowerShell-era entry ({s.command})")
    log(f"{prefix}copy viewer.py -> {cfg.viewer_dir}")
    for n in s.legacy_files:
        log(f"{prefix}remove old {cfg.viewer_dir / n}")
    log(f"{prefix}context menu verb HKCU\\{cfg.verb_key} ('Compression info')")
    if dry_run:
        return

    # 1. files first: the verb never points at something missing
    cfg.viewer_dir.mkdir(parents=True, exist_ok=True)
    tmp = cfg.viewer_dir / "viewer.py.tmp"
    shutil.copyfile(VIEWER_SOURCE, tmp)
    os.replace(tmp, cfg.viewer_dir / "viewer.py")

    # 2. registry: parents this install creates are recorded for uninstall
    created = []
    if s.present:   # ours (current or PowerShell era): rewrite it, keep its record
        k = _open(cfg, cfg.verb_key)
        with k:
            created = list(_value(k, "CreatedKeys", []) or [])
        _delete_tree(cfg, cfg.verb_key)
    else:
        created = [p for p in (cfg.assoc, cfg.assoc + r"\shell") if not _exists(cfg, p)]
    with winreg.CreateKeyEx(cfg.hive, cfg.verb_key, 0, winreg.KEY_WRITE) as k:
        winreg.SetValueEx(k, "MUIVerb", 0, winreg.REG_SZ, "Compression info")
        winreg.SetValueEx(k, "Icon", 0, winreg.REG_SZ, f'"{console_python()}",0')
        winreg.SetValueEx(k, MARKER, 0, winreg.REG_DWORD, 1)
        winreg.SetValueEx(k, "CreatedKeys", 0, winreg.REG_MULTI_SZ, created)
    with winreg.CreateKeyEx(cfg.hive, cfg.verb_key + r"\command", 0, winreg.KEY_WRITE) as k:
        winreg.SetValueEx(k, "", 0, winreg.REG_SZ, command_line(cfg))

    # 3. the PowerShell version's programs are no longer referenced
    for n in s.legacy_files:
        try:
            (cfg.viewer_dir / n).unlink()
        except OSError as e:
            log(f"  could not remove {cfg.viewer_dir / n}: {e.strerror}")
    _notify_shell()
    log("Installed: right-click an .mkv > Show more options > Compression info.")


def uninstall(cfg=None, dry_run=False, log=print):
    cfg = cfg or Config()
    s = get_state(cfg)
    prefix = "[dry run] " if dry_run else ""
    changed = False
    if s.present and not s.ours:
        log(f"HKCU\\{cfg.verb_key} was not created by this tool: left alone.")
    elif s.present:
        k = _open(cfg, cfg.verb_key)
        with k:
            created = list(_value(k, "CreatedKeys", []) or [])
        log(f"{prefix}remove HKCU\\{cfg.verb_key}" + (" (PowerShell-era entry)" if s.kind == "legacy-powershell" else ""))
        if not dry_run:
            _delete_tree(cfg, cfg.verb_key)
            for path in sorted(created, key=len, reverse=True):   # deepest first, only when empty
                if _is_empty(cfg, path):
                    winreg.DeleteKey(cfg.hive, path)
        changed = True

    files = [cfg.viewer_dir / n for n in ("viewer.py", "viewer.py.tmp", *LEGACY_FILES)]
    files = [f for f in files if f.exists()]
    if files:
        log(f"{prefix}remove {', '.join(f.name for f in files)} from {cfg.viewer_dir}")
        changed = True
        if not dry_run:
            for f in files:
                try:
                    f.unlink()
                except OSError as e:
                    log(f"  could not remove {f}: {e.strerror}")
    if not dry_run:
        for d in (cfg.viewer_dir, cfg.viewer_dir.parent):   # only when empty
            try:
                d.rmdir()
            except OSError:
                pass
    if not changed:
        log("Not installed: nothing to remove.")
    elif not dry_run:
        _notify_shell()
        log("Uninstalled.")
    for p in legacy_native_leftovers():
        log(f"Note: HKLM\\{p} is left from the old native property-handler install; removing it needs "
            f"administrator rights and is not done by this tool.")
