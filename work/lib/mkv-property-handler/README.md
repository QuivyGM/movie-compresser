# MKV metadata manager

A read-only terminal tool for the metadata that the Linux compression
scripts write into MKV outputs. It shows the compression fields and
validates them. On Windows it can also be added to Explorer's right-click
menu.

- **Launcher:** `window_tagger.py` in the repository root.
- **Requirements:** Python 3 with the standard library only. The optional
  track-title check also uses bash and ffprobe.
- **No admin needed:** nothing requires administrator rights.

```text
python window_tagger.py                       interactive menu (see below)
python window_tagger.py validate PATH ...     validate MKV files / folders (--no-titles: faster)
python window_tagger.py view PATH ...         print the fields (--stats: also bytes read)
python window_tagger.py install [--dry-run]   right-click .mkv > Show more options > Compression info
python window_tagger.py uninstall [--dry-run]
python window_tagger.py status
python window_tagger.py test                  about 5 s
```

`view` and `validate` work on any OS. `install`, `uninstall` and `status`
are Windows-only.

How paths are handled:

- A PATH is an MKV file or a folder. Folders are searched recursively.
- Directory symlinks and junctions are never followed; they are listed
  as skipped. OneDrive and other cloud folders are searched normally.
- Other media files (`.mp4`, `.avi`, …) are reported as unsupported.
- One failing file never stops a batch.

## Interactive menu

```text
MKV Metadata Manager

1) Validate MKV metadata
2) Windows metadata integration
3) Exit

Select [1-3]:
Enter MKV file or directory path:
>
```

- **Path input:** it may contain spaces and Unicode characters. A quoted
  path, as from Explorer's "Copy as path" or drag and drop, is accepted.
  An empty answer goes back to the menu.
- **1) Validate:** a per-file report, then a summary. The checks are
  described under "Validation" below.
- **2) Windows integration:** shows each MKV's compression fields, then
  reports the right-click entry. An entry that is already installed, or
  one this tool did not create, is left unchanged. If it is missing or
  broken, the tool offers to install it per user; the default is no.
  Properties > Details is reported as unavailable (see "Why not
  Properties > Details").

## Validation

Validation is read-only: no file is written, re-encoded or remuxed.

| Check               | Reported as                                                                 |
|---------------------|-----------------------------------------------------------------------------|
| Compression tags    | INVALID: CRF not a number or outside 0-51; tier not one of `compression_tier_name`'s names (read from `encode_common.sh`); COMPRESSION_* tags targeting a track or chapter |
|                     | INCONSISTENT: conflicting duplicate values; tier without CRF; tags on non-HEVC video |
| Compressor version  | INVALID: `COMPRESSION_TOOL` not `movie-compresser`; `COMPRESSION_DATE` not YYYY-MM-DD; a version that is an FFmpeg / x265 / MKVToolNix version string; the tags targeting a track |
|                     | INCONSISTENT: only some of the three provenance tags; conflicting duplicate values; provenance without CRF |
|                     | INFO: `Not recorded` (compressed before version tagging, not a problem); `unknown`; `-dirty` |
| CRF vs. the stream  | INCONSISTENT: the tag differs from the `rc=crf crf=…` x265 stored in the video track's CodecPrivate, or the stream is two-pass / ABR |
|                     | OUTDATED: an x265 CRF stream without the tag (probably from before tagging existed) |
| Statistics tags     | MISSING: BPS / NUMBER_OF_BYTES absent |
|                     | INVALID: the byte counts exceed the file size |
|                     | OUTDATED: written before the last mux (Segment DateUTC) |
| Codecs              | every track listed with codec, size or channels, language and flags |
| Track titles        | the rules of `verify.sh`'s own `check_track_titles`, run in Verify mode by `verify_titles.sh` |
| Structure           | INVALID: not Matroska, or an element truncated |

How the track-title check works:

- **With bash and ffprobe:** `verify_titles.sh` takes `check_track_titles`
  from `verify.sh` and calls it in Verify mode (`VALIDATE=0`), which
  never writes. As an extra safeguard, `mkvpropedit` is replaced by a
  function that refuses. Its verdicts are reported as STALE
  (INCONSISTENT), NOT STANDARD (OUTDATED) or MISSING.
- **Which bash:** on Windows, Git for Windows' bash is used, never WSL's.
- **Without bash or ffprobe:** only missing audio titles are reported.

Exit status of `validate`:

| Code | Meaning                                                   |
|------|-----------------------------------------------------------|
| 0    | no issues                                                 |
| 1    | metadata issues found                                     |
| 3    | invalid, unreadable or unsupported files were in the batch |

Example output:

```text
File: D:\Movies\Film (2024) HEVC Compact.mkv
  Compression tier:    Compact
  Compression CRF:     23.5
  Video encoder:       Lavc61.19.101 libx265
  Video stream size:   4.21 GB (4,523,456,789 bytes)
  Writing application: mkvmerge v88.0 ('All I Know') 64-bit
  Muxing application:  libebml v1.4.5 + libmatroska v1.7.1
```

Exit status (`viewer.py` and `view`):

| Code | Meaning                              |
|------|--------------------------------------|
| 0    | every file was read                  |
| 1    | a file is not (valid) Matroska       |
| 2    | usage error                          |
| 3    | a file could not be opened           |

Every file is still shown when one of them fails.

## Fields

The MKV is the only source. Nothing is written, generated or copied.

| Field                | Source in the MKV                                         |
|----------------------|-----------------------------------------------------------|
| Compression tool     | global tag `COMPRESSION_TOOL` (`movie-compresser`)        |
| Compressor version   | global tag `MOVIE_COMPRESSER_VERSION`                     |
| Compression date     | global tag `COMPRESSION_DATE` (YYYY-MM-DD, UTC)           |
| Compression tier     | global tag `COMPRESSION_TIER`                             |
| Compression CRF      | global tag `COMPRESSION_CRF`                              |
| Video encoder        | `ENCODER` tag of the first video track                    |
| Video stream size    | `NUMBER_OF_BYTES` statistics tag of the first video track |
| Writing application  | Segment Info `WritingApp`                                 |
| Muxing application   | Segment Info `MuxingApp`                                  |

- **Which tags count:** "global" means the Tag's Targets name no track,
  edition, chapter or attachment. This is the same rule as
  `_compression_tags_strip` in `encode_common.sh` and ffprobe's format tags.
- **Tag layouts:** both layouts are read: the current
  `mkv_set_compression_tags` (mkvpropedit, `TargetTypeValue 50`, appended
  after the clusters) and the older `ffmpeg -metadata` (empty Targets).
- **Compressor version** is the `git describe --tags --always --dirty` of
  the movie-compresser checkout, taken once when the encode job was
  created (`unknown` when Git or the repository was not available). It is
  never the FFmpeg, x265 or MKVToolNix version; those stay in *Video
  encoder*, *Video encode* and the application fields.
- **Missing information** is shown as `Not recorded`. That covers files from
  before tagging existed (also files with a CRF but no version: they were
  compressed before version tagging), stream copies and two-pass encodes.
  No version is ever filled in for them, and verify.sh's Validate + update
  never writes or changes a version.

## Reading limits

- Only the EBML header, SeekHead, Info, Tracks and Tags are read.
- Clusters (the audio and video data) are skipped by their size, never read.
- A file without a SeekHead gets one bounded 1 MiB tail scan.
- Each element and the total read are capped at 24 MiB; typically under
  4 KiB is read.
- Malformed or truncated files give an error line or partial fields,
  never a traceback.

## Explorer entry (Windows, per user)

`install` makes two changes, in this order:

1. **Copies `viewer.py`** to `%LOCALAPPDATA%\movie-compresser\MkvTagViewer\`.
   This happens first, so the entry never points at a missing file.
2. **Creates the menu entry**
   `HKCU\Software\Classes\SystemFileAssociations\.mkv\shell\MovieCompresser.CompressionInfo`
   with:
   - `MUIVerb`, `Icon`;
   - the ownership marker `MovieCompresserViewer=1`;
   - `CreatedKeys`: the parent keys this install had to create;
   - `command`: `"python.exe" -I "...\viewer.py" --pause "%1"`.

What happens on right-click:

- Explorer opens a console window for `python.exe`, and the fields are
  printed there.
- `--pause` keeps the window open until Enter is pressed.
- Plain `view` and `viewer.py` never pause.

Uninstall works as follows:

- It removes the entry only when it carries the marker.
- Of the parent keys listed in `CreatedKeys`, it removes the ones that are
  now empty.
- It deletes only the viewer's own files.
- An entry under that key that this tool did not create is refused on
  install and left alone on uninstall.

## Earlier versions

- **Entry left by the earlier PowerShell `window_tagger.ps1`:** it uses the
  same key and marker, with a command running `mkvtagsw.exe`. `install`
  migrates it, and deletes the old `mkvtagsw.exe` and `mkvtags.exe`;
  `uninstall` removes it.
- **Broken entries:** `status` flags such an entry as BROKEN when its
  program is missing.
- **Old native property-handler install:** if one ever left keys in HKLM,
  `status` and `uninstall` report them. Removing them needs administrator
  rights, so it is not done here.

## Why not Properties > Details

Windows 11 pins `.mkv` to its built-in "MF MKV Property Handler"
`{C591F150-4106-4141-B5C1-30B2101453BD}`. The pin is in
`HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\PropertySystem\SystemPropertyHandlers`,
a key owned by TrustedInstaller that Windows reads before
`PropertyHandlers`. A custom property handler is ignored, which was
verified and then removed. Overriding the pin would change a protected
Windows setting, so this tool never does it.

## Tests

Tests are in `tests/`, use `unittest`, and are run by
`python window_tagger.py test`. They work as follows:

- **Fixtures:** synthetic MKVs from `make_test_mkvs.py`, with no encoding.
  They include a sparse 256 MiB file, of which under 4 KiB may be read,
  and one case per validation finding (CRF mismatch, outdated statistics, …).
- **Batch tests** (`test_batch.py`):
  - a Unicode folder tree with a junction and a symlink that must not be
    followed;
  - the menu, driven both through stdin and in-process, including the
    install offer and the "already installed: left unchanged" path;
  - a check that `verify_titles.sh` loads `check_track_titles` from
    `verify.sh`.
- **Install tests:** they use a sandbox key
  (`HKCU\Software\movie-compresser-tests\<pid>`). They run the registered
  command exactly as Explorer would, with the Enter prompt answered.
- **Real round trip:** one per-user install/uninstall round trip runs only
  when the entry is not installed yet.
- **Checks on every run:** that HKLM is unchanged, and that the fixtures
  are byte-identical afterwards.
