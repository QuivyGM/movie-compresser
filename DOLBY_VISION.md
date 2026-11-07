# Dolby Vision in movie-compresser

How the movie and series workflows detect, preserve, convert or drop Dolby
Vision (DV), what is verified, and what cannot be preserved.
Implementation: `work/lib/hdr_dovi.sh`.

## Requirements

| Tool | Needed for | Minimum |
|---|---|---|
| `dovi_tool` | EL detection, RPU extraction / conversion / injection, verification | 2.1 (`export level5`); 2.0+ to tell MEL from FEL |
| `mkvmerge` (MKVToolNix) | DV configuration record + source timestamps | any version that writes the DV block-addition mapping (checked after every wrap) |
| `ffmpeg` / `ffprobe` with libx265 | detection, 10-bit HEVC encode, mux, decode check | — |

Static `dovi_tool` / `hdr10plus_tool` binaries can be put in `~/compress/work/bin`;
that directory is searched before `PATH`. The tool report (verbose mode, or
before any DV warning) shows the path and version of each tool.

## What happens per source

After the source analysis the menu prints what was detected:

```
DV detected:    profile 7, compatibility id 6 (HDR10 base layer, Blu-ray dual layer), BL+EL+RPU
                enhancement layer: FEL (full: carries additional picture data)
```

When the DV metadata can be carried over, you choose the output:

```
Dolby Vision output:
1) Preserve Dolby Vision (Profile 8.1 + HDR10)  [default]
2) HDR10 only
```

Enter (or no terminal input) takes option 1. The labels follow the actual
output (`Profile 8.4 + HLG` / `HLG only` for an HLG base layer). A series asks
once, for the first episode; every episode's job checks its own source again.

| Source | Option 1 (default) | Option 2 | Not possible |
|---|---|---|---|
| Profile 8.1 (HDR10 base) | RPU re-injected, stays 8.1 | plain HDR10 | — |
| Profile 8.4 (HLG base) | stays 8.4 | plain HLG | — |
| Profile 7 MEL | converted to 8.1 (dovi_tool mode 2); nothing visible lost | plain HDR10 | — |
| Profile 7 FEL | converted to 8.1: **RPU only, FEL picture data lost** (warning) | plain HDR10 | full FEL preservation |
| Profile 7, EL type unknown | as FEL, asks to confirm | plain HDR10 | — |
| Profile 5 (IPTPQc2) | — | — | skipped: no valid base layer, dropping DV would give wrong colours |
| Other profiles / compat ids, DV in AV1 | — | base layer only, by explicit choice | DV preservation |
| Tools missing / too old | — | base layer only, by explicit choice (the reason is shown first) | — |

The profile 7 enhancement-layer check depends on the tier as well (unchanged):
High / Base / Compact discard a FEL with a warning, Quality / Custom ask to
confirm, and an unknown EL type always asks. The menu samples the first 1000
frames. The job classifies every frame again and fails the item if it finds
an EL type that was not confirmed.

Dolby Vision is never dropped silently. An encode job refuses to queue a DV
source that has no DV decision. Option 2 and the "base layer only" choice
are both recorded in the queue summary as `DROPPED (by choice)`.

## Encode path (Option 1)

1. The RPU is extracted from the source with `dovi_tool extract-rpu`. Profile
   7 is converted with `editor` mode 2. When the video is downscaled
   (4K to 1080p), the L5 active-area offsets are rescaled.
2. x265 encodes the base layer exactly like a non-DV encode: the same CRF
   tier, retries, two-pass, 10-bit and HDR10 SEIs (`master-display`, `max-cll`,
   colour VUI). `-fps_mode passthrough` keeps the frames 1:1 with the RPUs.
   libx265's own RPU writing is disabled.
3. `dovi_tool inject-rpu` puts the RPU back. A frame-count mismatch fails the
   item, because dovi_tool would only warn and duplicate metadata.
4. `mkvmerge` writes the DV configuration record and the source frame
   timestamps, which keeps A/V sync. FFmpeg then muxes the result with the
   audio, subtitles, chapters and attachments, exactly as in the normal path.

The pipeline uses stream copy wherever it can: audio, subtitles and chapters
are never re-encoded. The video is encoded once (twice for two-pass). Option
2 and non-DV sources use the unchanged single-encode path.

## Verification (before the output gets its final name)

- Configuration record: the expected profile and compatibility id, RPU and
  BL present, no EL claimed.
- RPU count = source frames = output frames, so frames and RPUs are aligned.
- The RPUs read back from the output are byte-identical to the injected RPUs,
  or failing that have an identical `dovi_tool info` summary.
- The start of the output decodes without errors.
- Base-layer fallback: PQ/BT.2020 with the source's mastering display (8.1),
  HLG/BT.2020 (8.4), or SDR (8.2). The source's MaxCLL/MaxFALL is checked too.

If any check fails, the item fails. A complete encode that only failed the
verification is kept as `<output>.verify-failed`, never under the final name.
Failed and interrupted items keep their diagnosis files in
`work/logs/<job>/item-N.tmp/`: RPUs, `dovi_tool` summaries, timestamps,
`dovi_tool.log`, `mkvmerge.log`, `inject.log` and `decode_check.log`. The raw
HEVC intermediates (`video.hevc`, `video_dv.hevc`, `video_dv.mkv`) are as
large as the encode and are deleted so a failure cannot fill the disk.

## Limitations

- **FEL**: a single-layer profile 8.1 output cannot carry the full
  enhancement layer. Only the RPU (dynamic metadata) is kept, and the FEL's
  additional picture data (the residual for the 12-bit reconstruction) is
  lost. Dual-layer profile 7 output is not implemented.
- **MEL**: converting to 8.1 loses nothing visible, because the MEL carries no
  picture data beyond the base layer.
- **Dual-track profile 7** (EL in a separate stream, as on some disc remuxes):
  RPU extraction reads the main video stream only. If the RPU is not there,
  the job fails cleanly instead of producing an untagged output.
- **No VBV constraints**: the x265 CRF encode has no Dolby Vision level/VBV
  limits (`--dolby-vision-profile`). The stream is valid HEVC with valid RPUs,
  but very high-bitrate encodes may exceed what some hardware players accept
  for a given DV level.
- **Cropping** is not done by this pipeline. Scaling is the only geometry
  change, and L5 is rescaled for it.
- **HDR10+ and DV** together are both preserved: HDR10+ goes through x265's
  `dhdr10-info`.

## Playback compatibility

- **Profile 8.1** is supported by most DV TVs and by streaming and media
  players (Apple TV 4K, Shield, Fire TV 4K, Zidoo/Ugoos and similar, Plex/Kodi
  with DV-capable output). Players and TVs without DV show the HDR10 base
  layer with its static metadata. SDR displays get whatever tone mapping the
  player applies to HDR10.
- It is not a disc format, so it cannot be authored to UHD Blu-ray.
  Converting profile 7 to 8.1 changes how DV players render a FEL title,
  because they no longer receive the enhancement layer.
- **Profile 8.4 (HLG)** is less widely supported. Without DV support it plays
  as HLG.
- The output is MKV. Some devices only play DV from MP4 or TS. Remuxing the
  verified MKV with a DV-aware muxer keeps the RPUs.
