"""Batch processing and the interactive menu of window_tagger.py.

Paths: one MKV file, or a directory searched recursively. Directory
symlinks and junctions (any reparse point) are never followed; they are
listed as skipped. Every file is processed on its own: a failure is
reported and the batch continues. Nothing here writes to a movie file.
"""
import os
import stat
import sys
from pathlib import Path

import validate
import viewer

OTHER_MEDIA = {".mp4", ".m4v", ".avi", ".mov", ".wmv", ".ts", ".m2ts", ".mts", ".mpg", ".mpeg", ".flv",
               ".webm", ".vob", ".3gp", ".ogv", ".mka", ".mks", ".divx", ".rmvb"}
RULE = "=" * 60


class Selection:
    def __init__(self, root):
        self.root = root
        self.mkv = []            # MKV files, sorted
        self.unsupported = []    # other media files (not MKV)
        self.links = []          # directory symlinks / junctions not followed
        self.errors = []         # (path, message) of directories that could not be listed


LINK_TAGS = (getattr(stat, "IO_REPARSE_TAG_SYMLINK", 0xA000000C), getattr(stat, "IO_REPARSE_TAG_MOUNT_POINT", 0xA0000003))


def _is_link(entry):
    """Symlink or junction (mount point): never followed. Other reparse
    points, such as OneDrive / cloud folders, are ordinary folders."""
    try:
        if entry.is_symlink():
            return True
        return getattr(os.lstat(entry.path), "st_reparse_tag", 0) in LINK_TAGS
    except OSError:
        return True


def collect(path):
    """Selection for a file or a directory (recursive, links not followed)."""
    root = Path(path)
    sel = Selection(root)
    if root.is_file():
        (sel.mkv if root.suffix.lower() == ".mkv" else sel.unsupported).append(root)
        return sel
    stack = [root]
    while stack:
        d = stack.pop()
        try:
            with os.scandir(d) as it:
                entries = list(it)
        except OSError as e:
            sel.errors.append((Path(d), e.strerror or str(e)))
            continue
        for e in entries:
            p = Path(e.path)
            try:
                if _is_link(e) and e.is_dir():
                    sel.links.append(p)
                elif e.is_dir(follow_symlinks=False):
                    stack.append(p)
                elif e.is_file():
                    ext = p.suffix.lower()
                    if ext == ".mkv":
                        sel.mkv.append(p)
                    elif ext in OTHER_MEDIA:
                        sel.unsupported.append(p)
            except OSError as err:
                sel.errors.append((p, err.strerror or str(err)))
    key = lambda p: str(p).casefold()  # noqa: E731
    sel.mkv.sort(key=key)
    sel.unsupported.sort(key=key)
    sel.links.sort(key=key)
    return sel


def clean_path(text):
    """A path as typed or pasted: quotes ("Copy as path", drag and drop,
    PowerShell's & '...') and surrounding spaces removed, ~ expanded."""
    s = text.strip()
    if s.startswith("& "):
        s = s[2:].strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "\"'":
        s = s[1:-1]
    return os.path.expanduser(s.strip())


def _rel(sel, p):
    try:
        return str(p.relative_to(sel.root)) if sel.root.is_dir() else str(p)
    except ValueError:
        return str(p)


def _print_skipped(sel, out):
    for p in sel.unsupported:
        out(f"UNSUPPORTED  {_rel(sel, p)} (not MKV: not checked)")
    for p in sel.links:
        out(f"SKIPPED      {_rel(sel, p)} (directory link / junction: not followed)")
    for p, msg in sel.errors:
        out(f"ERROR        {_rel(sel, p)} ({msg})")


def run_validation(sel, titles=True, out=print):
    """Validates every MKV of sel; returns the exit status (0 no issues,
    1 metadata issues, 3 invalid / unreadable / unsupported files)."""
    bash, why_not = validate.title_checker() if titles else (None, "title check turned off")
    tiers = validate.tier_names()
    out(f"Track titles: {'verify.sh rules (bash: ' + bash + ')' if bash else 'missing titles only - ' + why_not}")
    counts = dict.fromkeys(("OK", "ISSUES", "INVALID", "UNREADABLE", "ERROR"), 0)
    kinds = dict.fromkeys(validate.PROBLEM_KINDS, 0)
    with_issues = []
    for n, p in enumerate(sel.mkv, 1):
        r = validate.validate_file(p, bash, why_not, tiers)
        counts[r.status] += 1
        for f in r.problems:
            kinds[f.kind] += 1
        if r.status != "OK":
            with_issues.append((r.status, _rel(sel, p), len(r.problems)))
        out("")
        out("\n".join(validate.format_report(r, f"[{n}/{len(sel.mkv)}] {_rel(sel, p)}")))
    out("")
    _print_skipped(sel, out)
    out(RULE)
    out("Summary (read-only: no file was modified)")
    out(f"  {'MKV files checked:':<24}{len(sel.mkv)}")
    for status, label in (("OK", "OK"), ("ISSUES", "With issues"), ("INVALID", "Invalid MKV"),
                          ("UNREADABLE", "Unreadable"), ("ERROR", "Check failed")):
        out(f"  {label + ':':<24}{counts[status]}")
    out(f"  {'Unsupported (not MKV):':<24}{len(sel.unsupported)}")
    if sel.links or sel.errors:
        out(f"  {'Links not followed:':<24}{len(sel.links)}")
        out(f"  {'Unlistable entries:':<24}{len(sel.errors)}")
    out(f"  {'Issues by kind:':<24}" + ", ".join(f"{k} {v}" for k, v in kinds.items()))
    for status, rel, n in with_issues:
        out(f"    {status:<10} {rel}" + (f" ({n})" if n else ""))
    out(RULE)
    if counts["INVALID"] + counts["UNREADABLE"] + counts["ERROR"] + len(sel.unsupported) + len(sel.errors):
        return 3
    return 1 if counts["ISSUES"] else 0


def run_integration(sel, ask=None, out=print):
    """Shows each MKV's compression info and reports / offers the per-user
    Explorer entry. Returns the exit status like viewer.py."""
    infos = []
    for n, p in enumerate(sel.mkv, 1):
        info = viewer.read_compression_info(p)
        infos.append(info)
        lines = viewer.describe(_rel(sel, p), info)
        lines[0] = f"[{n}/{len(sel.mkv)}] {lines[0][len('File: '):]}"
        out("")
        out("\n".join(lines))
    out("")
    _print_skipped(sel, out)
    out(RULE)
    shown = sum(1 for i in infos if i.is_matroska)
    out("Summary (read-only: nothing is written to the files)")
    out(f"  {'MKV files shown:':<24}{shown}")
    out(f"  {'Invalid MKV:':<24}{sum(1 for i in infos if not i.is_matroska and not i.error)}")
    out(f"  {'Unreadable:':<24}{sum(1 for i in infos if i.error)}")
    out(f"  {'Unsupported (not MKV):':<24}{len(sel.unsupported)}")
    out(f"  {'With compression tags:':<24}{sum(1 for i in infos if i.crf or i.tier)}")
    out(f"  {'With version recorded:':<24}{sum(1 for i in infos if i.version)}")
    out(RULE)
    _integration_status(ask, out)
    if any(i.error for i in infos) or sel.errors:
        return viewer.EXIT_UNREADABLE
    return viewer.EXIT_OK if all(i.is_matroska for i in infos) and not sel.unsupported else viewer.EXIT_NOT_MATROSKA


def _integration_status(ask, out):
    out("Windows integration")
    out("  Properties > Details: not available - Windows pins .mkv to its own property handler")
    out("  (SystemPropertyHandlers), which this tool does not override.")
    if sys.platform != "win32":
        out("  Right-click entry: Windows only.")
        return
    import installer
    s = installer.get_state()
    if s.kind == "python" and not s.broken and not s.viewer_outdated:
        out("  Right-click 'Compression info': installed - left unchanged.")
        return
    if s.kind == "foreign":
        out("  Right-click 'Compression info': an entry not created by this tool exists - left unchanged.")
        return
    reason = {"none": "not installed",
              "legacy-powershell": "installed by the old PowerShell version",
              "python": "installed but BROKEN (its program is missing)" if s.broken else
                        "installed, but its viewer copy is older (it does not show every field)"}[s.kind]
    if s.broken and s.kind == "legacy-powershell":
        reason += " - BROKEN (its program is missing)"
    out(f"  Right-click 'Compression info': {reason}.")
    if ask and ask("  Install / repair it for this user (no admin; no file is changed)? [y/N]: ").strip().lower() in ("y", "yes"):
        try:
            installer.install(log=lambda m: out("  " + m))
        except (installer.Refused, OSError) as e:
            out(f"  Not installed: {e}")
    else:
        out("  Left unchanged (python window_tagger.py install adds it).")


def _ask(prompt):
    return input(prompt)


def ask_path(ask=_ask, out=print):
    """Prompts until an existing file / directory is given; None on an empty
    answer (back to the menu)."""
    while True:
        out("Enter MKV file or directory path:")
        text = clean_path(ask("> "))
        if not text:
            return None
        if os.path.exists(text):
            return Path(text)
        out(f"Not found: {text}")


def menu(ask=_ask, out=print):
    """The interactive menu; returns when Exit is chosen or input ends."""
    try:
        while True:
            out("")
            out("MKV Metadata Manager")
            out("")
            out("1) Validate MKV metadata")
            out("2) Windows metadata integration")
            out("3) Exit")
            out("")
            choice = ask("Select [1-3]: ").strip()
            if choice == "3":
                return 0
            if choice not in ("1", "2"):
                out("Invalid selection.")
                continue
            path = ask_path(ask, out)
            if path is None:
                continue
            sel = collect(path)
            if not sel.mkv and not sel.unsupported:
                out(f"No MKV files in {path}" + (" (links / junctions are not followed)" if sel.links else ""))
                continue
            out(f"{len(sel.mkv)} MKV file(s) found" + (f", {len(sel.unsupported)} other media file(s)" if sel.unsupported else ""))
            if choice == "1":
                titles = True
                bash, why_not = validate.title_checker()
                if bash and len(sel.mkv) > 1:
                    titles = ask(f"Check track titles with verify.sh rules (about 2 s per file)? [Y/n]: ").strip().lower() not in ("n", "no")
                run_validation(sel, titles, out)
            else:
                run_integration(sel, ask, out)
    except (EOFError, KeyboardInterrupt):
        out("")
        return 0
