"""Shows the movie-compresser MKV compression tags (tier, CRF, encoder, ...)
read-only, in the terminal or from Explorer's right-click menu.

    python window_tagger.py view FILE.mkv...   print the fields in the terminal
    python window_tagger.py install            Explorer: right-click an .mkv >
                                               Show more options > Compression info
                                               (opens a console window with the fields)
    python window_tagger.py uninstall          remove that menu entry and its files
    python window_tagger.py status             what is installed
    python window_tagger.py test               lightweight test suite (~10 s)

Per user, no administrator rights, standard library only. Movie files are
only read. Code: work/lib/mkv-property-handler/.
"""
import argparse
import sys
from pathlib import Path

COMPONENT = Path(__file__).resolve().parent / "work" / "lib" / "mkv-property-handler"
sys.path.insert(0, str(COMPONENT))

import viewer  # noqa: E402


def require_windows():
    if sys.platform != "win32":
        print("window_tagger.py: install / uninstall / status are Windows-only (view works anywhere).", file=sys.stderr)
        sys.exit(2)
    import installer
    return installer


def cmd_status(_args):
    installer = require_windows()
    s = installer.get_state()
    cfg = installer.Config()
    row = lambda k, v: print(f"  {k:<26} {v}")  # noqa: E731
    print("Explorer menu entry (right-click > Show more options > Compression info)")
    row("Registry key", f"HKCU\\{cfg.verb_key}")
    row("State", {"none": "not installed", "python": "installed",
                  "legacy-powershell": "installed by the old PowerShell version (run install to migrate)",
                  "foreign": "present but NOT created by this tool (left alone)"}[s.kind]
        + (" - BROKEN: its program is missing (run install or uninstall)" if s.broken else ""))
    row("Command", s.command or "-")
    row("Viewer copy", cfg.viewer_dir / "viewer.py" if s.viewer_present else "absent")
    if s.legacy_files:
        row("Old PowerShell files", ", ".join(s.legacy_files))
    row("Python (for the menu)", installer.console_python())
    pin = installer.system_pin()
    row("Native Details tab", f"unavailable: Windows pins .mkv to {pin}" if pin else "not used by this tool")
    for p in installer.legacy_native_leftovers():
        row("Old native handler", f"HKLM\\{p} present (needs admin to remove)")


def cmd_install(args):
    installer = require_windows()
    try:
        installer.install(dry_run=args.dry_run)
    except installer.Refused as e:
        print(f"Refused: {e}", file=sys.stderr)
        return 1
    except OSError as e:
        print(f"Install failed: {e}", file=sys.stderr)
        return 1


def cmd_uninstall(args):
    require_windows().uninstall(dry_run=args.dry_run)


def cmd_view(args):
    argv = (["--stats"] if args.stats else []) + ["--"] + args.files
    return viewer.main(argv)


def cmd_test(_args):
    import unittest
    suite = unittest.defaultTestLoader.discover(str(COMPONENT / "tests"), top_level_dir=str(COMPONENT / "tests"))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    p = argparse.ArgumentParser(prog="window_tagger.py", description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="command", required=True)
    v = sub.add_parser("view", help="print the compression tags of MKV files")
    v.add_argument("files", nargs="+", metavar="FILE")
    v.add_argument("--stats", action="store_true", help="also print how many bytes were read")
    v.set_defaults(fn=cmd_view)
    for name, fn, text in (("install", cmd_install, "add the Explorer menu entry (per user)"),
                           ("uninstall", cmd_uninstall, "remove the Explorer menu entry")):
        q = sub.add_parser(name, help=text)
        q.add_argument("--dry-run", action="store_true", help="only print what would change")
        q.set_defaults(fn=fn)
    sub.add_parser("status", help="show what is installed").set_defaults(fn=cmd_status)
    sub.add_parser("test", help="run the lightweight tests").set_defaults(fn=cmd_test)
    args = p.parse_args()
    return args.fn(args) or 0


if __name__ == "__main__":
    sys.exit(main())
