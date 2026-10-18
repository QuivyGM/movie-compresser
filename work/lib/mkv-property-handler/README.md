# MKV compression info viewer

A read-only terminal viewer for the compression tags that the Linux
scripts write into MKV outputs. On Windows it can also be added to
Explorer's right-click menu.

- **Launcher:** `window_tagger.py` in the repository root.
- **Requirements:** Python 3 with the standard library only.
- **No admin needed:** nothing requires administrator rights.

```text
python window_tagger.py view FILE.mkv ...     print the fields (--stats: also bytes read)
python window_tagger.py install [--dry-run]   right-click .mkv > Show more options > Compression info
python window_tagger.py uninstall [--dry-run]
python window_tagger.py status
python window_tagger.py test                  about 10 s
```

`view` works on any OS. `install`, `uninstall` and `status` are
Windows-only.

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
- **Missing information** is shown as `Not recorded`. That covers files from
  before tagging existed, stream copies and two-pass encodes.

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
  They include a sparse 256 MiB file, of which under 4 KiB may be read.
- **Install tests:** they use a sandbox key
  (`HKCU\Software\movie-compresser-tests\<pid>`). They run the registered
  command exactly as Explorer would, with the Enter prompt answered.
- **Real round trip:** one per-user install/uninstall round trip runs only
  when the entry is not installed yet.
- **Checks on every run:** that HKLM is unchanged, and that the fixtures
  are byte-identical afterwards.
