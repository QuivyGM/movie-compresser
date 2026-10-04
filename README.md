# Movie Compressor: Files tab

A local web GUI for browsing and moving movie files between this Windows PC and remote Linux servers over
SSH/SFTP. This is the first module (file manager) of a larger compression GUI; compression and job tracking
are not part of it yet.

- Runs at `http://127.0.0.1:5000` and binds only to 127.0.0.1.
- All remote work goes over SSH/SFTP. Nothing is installed or listened on the servers, and no sudo is needed.
- No database. Transfers, probe results and scan results are kept in memory and lost on restart.

## External dependencies

| Where | What | Needed for |
|---|---|---|
| Windows PC | **Python 3.11 or newer** ([python.org](https://www.python.org/downloads/); tick "Add python.exe to PATH", or use the `py` launcher) | everything |
| Windows PC | **ffprobe** (part of FFmpeg; set its path in `[local] ffprobe`) | media columns and detailed scans of local files |
| Each server | **ffprobe** (path per server in `config.toml`) | media columns and detailed scans of remote files |
| Each server | GNU `bash`, `find`, `du`, `df`, `awk`; `pkill` (procps) | listing, folder sizes, free-space checks, scans; `pkill` only for cancelling a remote scan |
| Windows PC | **Git Bash** ([git-scm.com](https://git-scm.com/download/win)) | **tests only**: the in-process test SSH server runs remote commands through it |

Python packages are pinned to exact versions: `requirements.txt` (runtime) and `requirements-dev.txt` (tests). They are installed only into the project's `.venv`, never into the global Python.

## Setup and run

```bat
setup.bat          :: creates .venv with Python 3.11+, installs requirements.txt, creates config.toml if missing
notepad config.toml
run.bat            :: starts the app with .venv\Scripts\python -m app.main
```

Open http://127.0.0.1:5000.

- `setup.bat` stops with a clear message if Python 3.11+ isn't installed. Running it again is safe: it reuses `.venv` and re-installs the pinned versions.
- `run.bat` refuses to start without `.venv` or `config.toml`. To use a config file somewhere else, set `MC_CONFIG=path\to\config.toml`.
- At startup the app runs `ffprobe -version` on the local ffprobe. If that fails, a red banner explains why and local media info / scans are disabled, instead of every file showing an error. Remote locations keep working. After fixing it, click **Re-check** (a changed `config.toml` needs a restart).

## Configuration

See `config.example.toml`. Notes:

| Key | Meaning |
|---|---|
| `[local] roots` | Local folders the GUI may browse and write to. Everything else is rejected, including junctions/symlinks that point outside. |
| `[local] temp_dir` | Scratch space for server → server relay copies; needs room for the largest file you relay. |
| `[[servers]] host` | Hostname, IP, or a `Host` alias from `~/.ssh/config`. The SSH config is read, so `HostName`, `Port`, `User` and `IdentityFile` from it apply. |
| `port`, `user` | Optional. Leave them out to use `~/.ssh/config`. Setting `port = 22` **overrides** a `Port` in your SSH config. |
| `key_file` | Optional. Leave it out to use ssh-agent (Windows OpenSSH agent or Pageant) or the default keys. Passwords are never used or stored. |
| `ffprobe` (server) | Prefer an absolute path. A non-interactive SSH session often has a minimal `PATH`, so a plain `ffprobe` may not be found. `~/bin/ffprobe` is expanded. |
| `roots` (server) | Absolute paths or `~/...`. `~` is expanded once at connect time using the remote `$HOME`, and symlinks are resolved. |
| `[app] max_transfers` | Concurrent transfers across all servers (default 2). |
| `[app] probe_concurrency` | Concurrent fast probes / folder-size jobs per location (default 4). |

**Host keys are checked strictly** against `~/.ssh/known_hosts`. Connect once with a normal `ssh` command so the host key is recorded there; unknown host keys are refused.

## Using it

- **Panes:** each pane has its own location and path. Use **+ Pane** to add more.
  - An empty path shows the configured roots.
  - Double-click a folder to open it; **↑ Up** goes back up.
  - **Test** checks the connection (`echo ok`) and shows the latency.
- **Listing:** appears immediately. Media columns and folder sizes fill in afterwards, as background `ffprobe` and `du`/`find` jobs finish.
  - Missing metadata is shown as `—`; no values are invented.
  - Bitrates come from stream metadata (`bit_rate`, or the Matroska `BPS` statistics tag).
- **Detailed scan:** selecting a file shows its full details. **Detailed scan** then reads every packet in one `ffprobe -show_entries packet=stream_index,pts,duration,size` pass and measures each stream's real size and its own duration: (last packet pts + its duration − first packet pts) × time_base. Bitrate = size × 8 / that duration.
  - If a stream's duration is unavailable or under 1 s, the container duration is used instead, and the table marks it "(container)".
  - It reads the whole file, so expect roughly disk/NFS read speed.
  - It shows progress and can be cancelled.
  - On remote files, the totals are computed by `awk` on the server, so only a few lines come back over SSH.
- **Transfers:** "Send to" defaults to the other pane's location and folder.
  - Files and folders are both supported; folders are copied recursively, including empty sub-folders.
  - If the destination already exists, you're asked to overwrite, skip, or rename (`name (1).ext`).
  - **Relay:** server → server goes through `temp_dir`, and the temp copy is deleted afterwards.

- **Stale `.part` files:** at startup, and whenever you click **Check for stale files**, every configured root (local and each reachable server) is searched for `*.part` files. Files that running transfers are writing are excluded, and unreachable servers are listed as skipped.
  - The dialog shows location, path, size and modified time, with **Delete selected**, **Delete all** (both ask for confirmation) and **Ignore**.
  - Nothing is ever deleted automatically. Each file is re-validated before deletion: it must end in `.part`, be a regular file inside a configured root (same path checks as browsing), and not belong to a running transfer.
  - **Ignore** remembers those files in this browser, so the dialog doesn't pop up for them again at startup; the button still lists them.

### How transfers work

1. **Free-space check** at queue time, and again when the transfer starts: `shutil.disk_usage` locally, `df -B1 --output=avail` remotely. For a relay, the temp dir is checked too.
2. **Write to `<name>.part`.** Uploads use SFTP with asyncssh's pipelined parallel requests; the block size is negotiated with the server.
3. **Verify** that the `.part` size equals the source size.
4. **Rename into place.**
   - Without "overwrite", the rename refuses to replace an existing file.
   - With "overwrite", it uses an atomic `posix-rename` remotely and `os.replace` locally.
5. **Set the modification time** to match the source.
6. **On cancel or failure,** the `.part` file is deleted. There is no resume (out of scope); a cancelled transfer restarts from zero.

## Tests

```bat
setup.bat dev                         :: adds the pinned test packages to .venv
.venv\Scripts\python -m pytest
```

- **Unit tests:**
  - ffprobe normalization, using saved JSON samples: HEVC 4K + DTS-HD MA + subtitles; AVC 1080p + AC-3 + cover art; missing bitrate metadata; no default audio flag
  - packet aggregation and per-stream durations (late-starting stream, B-frame reordering, container fallback)
  - stale `.part` detection/deletion rules
  - the local ffprobe startup check
  - path restriction / traversal / junction escapes
  - `shlex` quoting of awkward filenames, checked through a real bash
  - speed/ETA
- **Remote and transfer tests** run against an **in-process asyncssh server**:
  - SFTP is served from a temp directory.
  - Exec requests run the app's real `du`/`df`/`find`/`ffprobe | awk` commands through Git Bash.
  - So upload, download, folder copy, relay, conflict handling, cancel cleanup, the concurrency limit and remote scans are all exercised for real.
  - These need Git Bash; tests that need `ffmpeg`/`ffprobe` on `PATH` are skipped without them.
- **Integration tests against your real server (opt-in):** list, fast probe, and a 5 MiB round trip with size verification. They write and then remove one temporary file in the server's first root and in your first local root.

  ```powershell
  $env:MC_INTEGRATION = "1"; $env:MC_INTEGRATION_SERVER = "milab"; .venv\Scripts\python -m pytest -m integration
  ```

## Known limitations

- **State is in memory only.** Restarting the app forgets transfers, the probe cache and scan results. Stopping with Ctrl+C cancels running transfers and removes their `.part` files; a hard kill can leave a stale `.part` behind (use **Check for stale files**).
- **No resumable transfers, and no direct server → server copies** (relay only). Relay needs local temp space for the whole file or folder and moves the data twice over your home connection.
- **Symlinks inside folders being transferred are skipped** on the remote side (`find -type f` doesn't follow links). Local links/junctions inside a root that point outside it are rejected when browsing them directly.
- **Remote names that aren't valid on Windows** (`:`, `?`, `*`, trailing dots, `CON`, …) make a download or relay fail early with a clear message; they are not renamed automatically.
- **Folder sizes:** `du -sb` measures apparent size. Local folder sizes come from a Python walk and can be slow on very large trees. Folder sizes are cached for 60 s.
- **Detailed-scan durations** come from packet timestamps. A stream with gaps in the middle (e.g. sparse subtitles) still counts its full first-to-last span.
- **Stale-file search** walks every root in full: locally with Python, remotely with one `find` per server. On very large trees it can take a while; a server that doesn't answer within 45 s is reported as skipped.
- **Cancelling a remote scan** relies on `pkill` on the server. Without it, the remote `ffprobe` keeps running until it hits a broken pipe.
- **Remote filenames that aren't valid UTF-8** are passed through using surrogate escapes. They work for listing and transfers, but may display oddly.
- **No authentication on the web UI.** It relies on the 127.0.0.1 bind plus a Host-header check (DNS-rebinding protection). Any local process or browser tab on this PC can still call the API.
