"""Shows and validates the movie-compresser MKV metadata (tier, CRF, encoder,
codecs, track titles, ...) read-only, in the terminal or from Explorer's
right-click menu.

    python window_tagger.py                    interactive menu (validate / Windows
                                               integration for a file or a folder)
    python window_tagger.py validate PATH...   validate MKV files / folders (recursive)
    python window_tagger.py view PATH...       print the compression fields
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

import batch  # noqa: E402
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
    row("Viewer copy", (f"{cfg.viewer_dir / 'viewer.py'}" + (" - OUTDATED (run install to update it)"
                                                                if s.viewer_outdated else ""))
        if s.viewer_present else "absent")
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
    files = []
    for f in args.files:   # a folder stands for its MKV files (recursive, links not followed)
        files += [str(p) for p in batch.collect(f).mkv] if Path(f).is_dir() else [f]
    if not files:
        print("No MKV files found.", file=sys.stderr)
        return viewer.EXIT_NOT_MATROSKA
    argv = (["--stats"] if args.stats else []) + ["--"] + files
    return viewer.main(argv)


def cmd_validate(args):
    status = 0
    for path in args.paths:
        if not Path(path).exists():
            print(f"Not found: {path}", file=sys.stderr)
            status = max(status, 3)
            continue
        status = max(status, batch.run_validation(batch.collect(path), titles=not args.no_titles))
    return status


def cmd_test(_args):
    import unittest
    suite = unittest.defaultTestLoader.discover(str(COMPONENT / "tests"), top_level_dir=str(COMPONENT / "tests"))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    if sys.stdin and not sys.stdin.isatty() and hasattr(sys.stdin, "reconfigure"):
        sys.stdin.reconfigure(encoding="utf-8")   # piped answers / paths (a console is read as Unicode anyway)
    p = argparse.ArgumentParser(prog="window_tagger.py", description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="command")
    q = sub.add_parser("validate", help="validate MKV metadata (read-only); exit 0 OK, 1 issues, 3 invalid files")
    q.add_argument("paths", nargs="+", metavar="PATH", help="MKV file or folder (searched recursively)")
    q.add_argument("--no-titles", action="store_true", help="skip verify.sh's track-title rules (faster)")
    q.set_defaults(fn=cmd_validate)
    v = sub.add_parser("view", help="print the compression tags of MKV files")
    v.add_argument("files", nargs="+", metavar="PATH")
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
    if not args.command:
        return batch.menu()
    return args.fn(args) or 0


if __name__ == "__main__":
    sys.exit(main())
