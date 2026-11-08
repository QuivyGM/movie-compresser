#!/usr/bin/env python3
"""Compression provenance manifest of movie-compresser (PROVENANCE.md).

Python 3.6+, standard library only. Normally run through provenance.sh in
the project root; the job runtime calls `ingest` after every verified
output (work/lib/provenance.sh item_provenance_record).

Commands
  ingest            merge the events jobs left in the spool into the manifest
  scan PATH...      report embedded provenance / manifest record / logs / media
                    properties of existing files (read-only)
  tag PATH...       give files without provenance an ID tag and a record
                    (tags only, no re-encode; --dry-run shows the plan)
  relink PATH...    record files that were moved or renamed (manifest only;
                    --dry-run shows the plan)
  compare [PATH...] compare the recorded compressor versions with the
                    current checkout (read-only)
  show ID|PATH      print one record
  rebuild           rebuild the manifest from the journal

Storage (work/logs/provenance, or --manifest-dir / PROVENANCE_DIR)
  manifest.json      one record per output file (atomic replace, .bak kept)
  journal.jsonl      every applied entry, append-only: the manifest can be
                     rebuilt from it (rebuild, or automatically when both
                     manifest.json and manifest.json.bak are unreadable)
  spool/<op>/        events written by jobs, removed once applied
  .lock/             writer lock (mkdir); stale after 10 minutes
"""

import argparse
import contextlib
import copy
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

SCHEMA = "movie-compresser/provenance-manifest/1"
TOOL = "movie-compresser"
LIB_DIR = os.path.dirname(os.path.abspath(__file__))
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
SHA_RE = re.compile(r"^[0-9a-f]{40}([0-9a-f]{24})?$")
EPISODE_RE = re.compile(r"(?i)\bS(\d{1,3})[ ._-]?E(\d{1,4})\b")
TAG_NAMES = ("PROVENANCE_TOOL", "PROVENANCE_ID", "PROVENANCE_STATUS", "PROVENANCE_COMMIT",
             "PROVENANCE_TREE", "PROVENANCE_TIME", "PROVENANCE_PRESET", "PROVENANCE_OPS",
             "PROVENANCE_PARENT")
LEGACY_TAGS = ("COMPRESSION_TOOL", "MOVIE_COMPRESSER_VERSION", "COMPRESSION_DATE",
               "COMPRESSION_CRF", "COMPRESSION_TIER")
PROCESSING_OPS = ("compress", "stream-copy", "audio-compress", "remux")
MAX_ATTACHMENTS = 200


def utcnow():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def eprint(*a):
    print(*a, file=sys.stderr)


def run(cmd, timeout=900, text=True):
    """(returncode, stdout); never raises (127 when the tool is missing)."""
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           timeout=timeout, universal_newlines=text)
        return p.returncode, p.stdout
    except (OSError, subprocess.SubprocessError):
        return 127, ""


_NATIVE_CACHE = {}


def native(path):
    """A path this Python can open. Under Windows a POSIX path written by
    Git Bash (/c/..., /tmp/...) is converted with cygpath."""
    if not path or os.name != "nt" or not path.startswith("/"):
        return path
    if path not in _NATIVE_CACHE:
        rc, out = run(["cygpath", "-w", path], timeout=20)
        _NATIVE_CACHE[path] = out.strip() if rc == 0 and out.strip() else path
    return _NATIVE_CACHE[path]


def pkey(path):
    """Comparable form of a path (absolute, case-normalised on Windows)."""
    if not path:
        return ""
    return os.path.normcase(os.path.abspath(native(path)))


def same_path(a, b):
    return bool(a) and bool(b) and pkey(a) == pkey(b)


def file_size(path):
    try:
        return os.path.getsize(native(path))
    except OSError:
        return None


def none_if(v, *empty):
    if v is None:
        return None
    v = str(v)
    if v in ("", "-", "unknown", "N/A") or v in empty:
        return None
    return v


def to_int(v):
    try:
        return int(str(v).strip())
    except (TypeError, ValueError):
        return None


def to_float(v):
    try:
        return float(str(v).strip())
    except (TypeError, ValueError):
        return None


# ----------------------------------------------------------------------
# Manifest store
# ----------------------------------------------------------------------

class Store:
    def __init__(self, pdir):
        self.dir = pdir
        self.manifest = os.path.join(pdir, "manifest.json")
        self.bak = self.manifest + ".bak"
        self.journal = os.path.join(pdir, "journal.jsonl")
        self.spool = os.path.join(pdir, "spool")
        self.lockdir = os.path.join(pdir, ".lock")
        self.notes = []

    # -- locking ------------------------------------------------------
    @contextlib.contextmanager
    def locked(self, timeout=180, stale=600):
        os.makedirs(self.dir, exist_ok=True)
        start = time.time()
        while True:
            try:
                os.mkdir(self.lockdir)
                break
            except FileExistsError:
                try:
                    age = time.time() - os.stat(self.lockdir).st_mtime
                except OSError:
                    continue
                if age > stale:
                    shutil.rmtree(self.lockdir, ignore_errors=True)
                    self.notes.append("removed a stale manifest lock (%d s old)" % age)
                    continue
                if time.time() - start > timeout:
                    raise RuntimeError("manifest is locked by another process (%s)" % self.lockdir)
                time.sleep(0.2)
        try:
            with open(os.path.join(self.lockdir, "owner"), "w") as f:
                f.write("%d %s\n" % (os.getpid(), utcnow()))
        except OSError:
            pass
        try:
            yield
        finally:
            shutil.rmtree(self.lockdir, ignore_errors=True)

    # -- reading ------------------------------------------------------
    @staticmethod
    def _read_json(path):
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict) or data.get("schema") != SCHEMA or \
                not isinstance(data.get("records"), dict):
            raise ValueError("not a provenance manifest")
        return data

    def empty(self):
        return {"schema": SCHEMA, "updated": None, "records": {}}

    def load(self):
        """The manifest; recovered from manifest.json.bak or rebuilt from the
        journal when manifest.json is unreadable (noted in self.notes)."""
        if os.path.exists(self.manifest):
            try:
                return self._read_json(self.manifest)
            except (OSError, ValueError) as e:
                self.notes.append("manifest.json unreadable (%s)" % e)
        if os.path.exists(self.bak):
            try:
                data = self._read_json(self.bak)
                self.notes.append("manifest recovered from manifest.json.bak")
                self._replay(data, since_bak=True)
                return data
            except (OSError, ValueError) as e:
                self.notes.append("manifest.json.bak unreadable (%s)" % e)
        if os.path.exists(self.journal):
            data = self.empty()
            n = self._replay(data)
            self.notes.append("manifest rebuilt from the journal (%d entries)" % n)
            return data
        return self.empty()

    def journal_entries(self):
        if not os.path.exists(self.journal):
            return
        with open(self.journal, encoding="utf-8") as f:
            for n, line in enumerate(f, 1):
                line = line.strip()
                if not line:
                    continue
                try:
                    yield json.loads(line)
                except ValueError:
                    # a torn last line (crash while appending): skipped
                    self.notes.append("journal line %d unreadable: skipped" % n)

    def _replay(self, data, since_bak=False):
        n = 0
        for e in self.journal_entries():
            if apply_entry(data, e):
                n += 1
        if n:
            data["updated"] = utcnow()
            if since_bak:
                self.notes.append("%d journal entries newer than the backup re-applied" % n)
        return n

    # -- writing ------------------------------------------------------
    def save(self, data):
        data["updated"] = utcnow()
        os.makedirs(self.dir, exist_ok=True)
        tmp = "%s.tmp-%d" % (self.manifest, os.getpid())
        with open(tmp, "w", encoding="utf-8", newline="\n") as f:
            json.dump(data, f, indent=1, ensure_ascii=False)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        # keep the last good manifest as the backup (never a corrupt one)
        if os.path.exists(self.manifest):
            try:
                self._read_json(self.manifest)
                shutil.copyfile(self.manifest, self.bak + ".tmp")
                os.replace(self.bak + ".tmp", self.bak)
            except (OSError, ValueError):
                pass
        os.replace(tmp, self.manifest)

    def append_journal(self, entries):
        if not entries:
            return
        os.makedirs(self.dir, exist_ok=True)
        # a torn last line (crash while appending) must not swallow the next entry
        try:
            with open(self.journal, "rb") as f:
                f.seek(-1, os.SEEK_END)
                torn = f.read(1) != b"\n"
        except OSError:
            torn = False
        with open(self.journal, "a", encoding="utf-8", newline="\n") as f:
            if torn:
                f.write("\n")
            for e in entries:
                f.write(json.dumps(e, ensure_ascii=False, separators=(",", ":")) + "\n")
            f.flush()
            os.fsync(f.fileno())

    def commit(self, entries):
        """Journal first, then the manifest: a crash in between is repaired
        by the next load / ingest (entries are idempotent)."""
        with self.locked():
            data = self.load()
            self.append_journal(entries)
            changed = [e for e in entries if apply_entry(data, e)]
            self.save(data)
            return data, changed


# ----------------------------------------------------------------------
# Applying entries (deterministic and idempotent: replaying the journal
# gives the same manifest)
# ----------------------------------------------------------------------

def all_op_ids(rec):
    ids = set()
    for op in [rec.get("original")] + list(rec.get("operations") or []):
        if isinstance(op, dict) and op.get("op_id"):
            ids.add(op["op_id"])
    return ids


def apply_entry(data, e):
    recs = data["records"]
    kind = e.get("entry")
    if kind == "output":
        return _apply_output(recs, e)
    if kind == "adopt":
        return _apply_adopt(recs, e)
    if kind == "relocate":
        return _apply_relocate(recs, e)
    return False


def _supersede(recs, rid, path, when):
    for other in recs.values():
        if other["id"] == rid or other.get("status") != "active":
            continue
        if same_path((other.get("current") or {}).get("path"), path):
            other["status"] = "replaced"
            other["replaced_by"] = rid
            other["replaced_at"] = when


def _apply_output(recs, e):
    rid = e["id"]
    op = e["op"]
    if rid in recs:
        return False
    for r in recs.values():
        if op["op_id"] in all_op_ids(r):
            return False
    parent_id = e.get("parent_id")
    parent = recs.get(parent_id) if parent_id else None
    rec = {
        "id": rid,
        "kind": e.get("kind") or "unknown",
        "status": "active",
        "created": op["time"],
        "provenance": "recorded",
        "current": dict(e["file"]),
        "locations": [{"path": e["file"]["path"], "since": op["time"], "reason": "created"}],
        "lineage": {"parent_id": parent_id, "parent_in_manifest": parent is not None,
                    "source_path": (op.get("source") or {}).get("path")},
        "tags_embedded": bool(e.get("tags_embedded")),
    }
    if e.get("series"):
        rec["series"] = e["series"]
    if rec["kind"] == "unknown" and parent:
        rec["kind"] = parent.get("kind", "unknown")
        if parent.get("series"):
            rec["series"] = parent["series"]
    if op["type"] == "compress":
        # a new video encode: this operation IS the original processing
        rec["original"] = op
        rec["operations"] = []
    else:
        # the video stream was copied: its history is the parent's
        if parent:
            rec["original"] = copy.deepcopy(parent.get("original"))
            if isinstance(rec["original"], dict):
                rec["original"]["inherited_from"] = parent_id
            rec["operations"] = copy.deepcopy(parent.get("operations") or []) + [op]
            rec["provenance"] = parent.get("provenance", "recorded")
            if rec["provenance"] == "recorded" and (rec["original"] or {}).get("status") == "unknown":
                rec["provenance"] = "partial"
        else:
            rec["original"] = {
                "status": "unknown",
                "note": "the video stream was copied from a source without a provenance record; "
                        "how that video was encoded is unknown",
            }
            rec["operations"] = [op]
            rec["provenance"] = "partial"
    _supersede(recs, rid, rec["current"]["path"], op["time"])
    recs[rid] = rec
    return True


def _apply_adopt(recs, e):
    rid = e["id"]
    op = e["op"]
    rec = recs.get(rid)
    if rec is not None:
        if op["op_id"] in all_op_ids(rec):
            return False
        rec.setdefault("operations", []).append(op)
        if e.get("tags_embedded"):
            rec["tags_embedded"] = True
        if e.get("file") and not same_path(rec["current"].get("path"), e["file"]["path"]):
            rec["current"] = dict(e["file"])
            rec.setdefault("locations", []).append(
                {"path": e["file"]["path"], "since": op["time"], "reason": "found by scan"})
        return True
    recovered = e.get("recovered") or {}
    rec = {
        "id": rid,
        "kind": e.get("kind") or "unknown",
        "status": "active",
        "created": op["time"],
        "provenance": "recovered" if recovered.get("fields") else "unknown",
        "current": dict(e["file"]),
        "locations": [{"path": e["file"]["path"], "since": op["time"], "reason": "adopted"}],
        "lineage": {"parent_id": None, "parent_in_manifest": False, "source_path": None},
        "tags_embedded": bool(e.get("tags_embedded")),
        "original": {
            "status": "recovered" if recovered.get("fields") else "unknown",
            "note": "processed before provenance tracking (or the record was lost): "
                    "only the values listed under 'recovered' are known, each with its source",
            "recovered": recovered,
            "media_at_adoption": e.get("media"),
        },
        "operations": [op],
    }
    if e.get("series"):
        rec["series"] = e["series"]
    recs[rid] = rec
    return True


def _apply_relocate(recs, e):
    rec = recs.get(e["id"])
    if rec is None:
        return False
    for loc in rec.get("locations") or []:
        if loc.get("op_id") == e["op_id"]:
            return False
    rec["current"]["path"] = e["to"]
    rec["current"]["name"] = os.path.basename(e["to"])
    if e.get("size") is not None:
        rec["current"]["size"] = e["size"]
    rec.setdefault("locations", []).append(
        {"path": e["to"], "since": e["time"], "reason": e.get("reason", "moved"),
         "from": e.get("from"), "op_id": e["op_id"]})
    if rec.get("status") == "missing":
        rec["status"] = "active"
    return True


# ----------------------------------------------------------------------
# Media properties (compact, from ffprobe JSON)
# ----------------------------------------------------------------------

def ffprobe_json(path):
    rc, out = run(["ffprobe", "-v", "error", "-show_format", "-show_streams", "-show_chapters",
                   "-of", "json", native(path)], timeout=300)
    if rc != 0 or not out.strip():
        return None
    try:
        return json.loads(out)
    except ValueError:
        return None


def _tags(d):
    return {str(k).upper(): v for k, v in (d.get("tags") or {}).items()}


def _bit_depth(st):
    b = to_int(st.get("bits_per_raw_sample"))
    if b:
        return b
    m = re.search(r"p(\d{2})(le|be)?$", st.get("pix_fmt") or "")
    if m:
        return int(m.group(1))
    if re.match(r"^(yuv|yuvj|nv|gray)\d*p?$", st.get("pix_fmt") or "") or \
            (st.get("pix_fmt") or "") in ("yuv420p", "yuv422p", "yuv444p", "nv12", "yuvj420p"):
        return 8
    return None


def _bitrate(st):
    br = to_int(st.get("bit_rate"))
    if br:
        return br, "stream"
    t = _tags(st)
    for k in t:
        if k == "BPS" or k.startswith("BPS-") or k.startswith("BPS_"):
            v = to_int(t[k])
            if v:
                return v, "statistics tag"
    return None, None


def _fps(st):
    for k in ("avg_frame_rate", "r_frame_rate"):
        v = st.get(k)
        if v and v not in ("0/0",):
            try:
                n, d = v.split("/")
                if int(d):
                    return v, round(int(n) / int(d), 3)
            except ValueError:
                pass
    return None, None


def _disp(st, key):
    return bool((st.get("disposition") or {}).get(key))


def _side_data(st):
    out = {}
    for sd in st.get("side_data_list") or []:
        t = (sd.get("side_data_type") or "").lower()
        if "dovi" in t or "dolby" in t:
            out["dolby_vision"] = {k: sd.get(k) for k in (
                "dv_version_major", "dv_version_minor", "dv_profile", "dv_level",
                "rpu_present_flag", "el_present_flag", "bl_present_flag",
                "dv_bl_signal_compatibility_id") if k in sd}
        elif "mastering" in t:
            out["mastering_display"] = True
        elif "content light" in t:
            out["content_light_level"] = {k: sd.get(k) for k in ("max_content", "max_average") if k in sd}
    return out


def compact_media(probe, path=None, size=None, hdr=None):
    """The properties worth keeping (no full dump): container, video, audio,
    subtitle tracks, chapter count + digest, attachments."""
    if not probe:
        return None
    fmt = probe.get("format") or {}
    ftags = _tags(fmt)
    m = {
        "path": path or fmt.get("filename"),
        "name": os.path.basename(path or fmt.get("filename") or ""),
        "size": size if size is not None else to_int(fmt.get("size")),
        "container": fmt.get("format_name"),
        "duration_s": to_float(fmt.get("duration")),
        "bit_rate": to_int(fmt.get("bit_rate")),
        "title": ftags.get("TITLE"),
        "video": [], "audio": [], "subtitles": [], "attachments": [],
    }
    for st in probe.get("streams") or []:
        ct = st.get("codec_type")
        t = _tags(st)
        if ct == "video" and _disp(st, "attached_pic"):
            if len(m["attachments"]) < MAX_ATTACHMENTS:
                m["attachments"].append({"filename": t.get("FILENAME"), "mimetype": t.get("MIMETYPE"),
                                         "kind": "cover art (attached picture)"})
            continue
        if ct == "video":
            br, brs = _bitrate(st)
            fr, fps = _fps(st)
            v = {
                "index": st.get("index"), "codec": st.get("codec_name"), "profile": st.get("profile"),
                "width": st.get("width"), "height": st.get("height"),
                "frame_rate": fr, "fps": fps, "pix_fmt": st.get("pix_fmt"),
                "bit_depth": _bit_depth(st), "bit_rate": br, "bit_rate_from": brs,
                "color": {"primaries": st.get("color_primaries"), "transfer": st.get("color_transfer"),
                          "matrix": st.get("color_space"), "range": st.get("color_range")},
                "language": t.get("LANGUAGE"), "title": t.get("TITLE"), "default": _disp(st, "default"),
            }
            sd = _side_data(st)
            if sd:
                v["side_data"] = sd
            m["video"].append(v)
        elif ct == "audio":
            br, brs = _bitrate(st)
            m["audio"].append({
                "index": st.get("index"), "codec": st.get("codec_name"), "profile": st.get("profile"),
                "channels": st.get("channels"), "layout": st.get("channel_layout"),
                "sample_rate": to_int(st.get("sample_rate")), "bit_rate": br, "bit_rate_from": brs,
                "language": t.get("LANGUAGE"), "title": t.get("TITLE"),
                "default": _disp(st, "default"), "forced": _disp(st, "forced"),
                "commentary": _disp(st, "comment"),
            })
        elif ct == "subtitle":
            m["subtitles"].append({
                "index": st.get("index"), "codec": st.get("codec_name"),
                "language": t.get("LANGUAGE"), "title": t.get("TITLE"),
                "default": _disp(st, "default"), "forced": _disp(st, "forced"),
                "hearing_impaired": _disp(st, "hearing_impaired"),
            })
        elif ct == "attachment":
            if len(m["attachments"]) < MAX_ATTACHMENTS:
                m["attachments"].append({"filename": t.get("FILENAME"), "mimetype": t.get("MIMETYPE")})
    ch = probe.get("chapters") or []
    dig = hashlib.sha1()
    for c in ch:
        dig.update(("%s|%s\n" % (c.get("start_time"), _tags(c).get("TITLE"))).encode("utf-8"))
    m["chapters"] = {"count": len(ch), "digest": dig.hexdigest()[:16] if ch else None}
    if hdr and m["video"]:
        m["video"][0]["dynamic_range"] = hdr
    return m


def media_line(m):
    """One-line description of compact media properties."""
    if not m:
        return "unreadable"
    parts = []
    for v in m.get("video") or []:
        dr = v.get("dynamic_range") or {}
        hdr = dr.get("label")
        if not hdr:
            tr = (v.get("color") or {}).get("transfer")
            hdr = {"smpte2084": "PQ (HDR10?)", "arib-std-b67": "HLG"}.get(tr, "SDR" if tr else None)
            sd = v.get("side_data") or {}
            if sd.get("dolby_vision"):
                hdr = "DV %s + %s" % (sd["dolby_vision"].get("dv_profile"), hdr or "?")
        parts.append("%s %sx%s %s-bit%s" % (v.get("codec"), v.get("width"), v.get("height"),
                                            v.get("bit_depth") or "?", (" " + hdr) if hdr else ""))
        break
    a = m.get("audio") or []
    if a:
        parts.append("%d audio (%s)" % (len(a), ", ".join(
            "%s %sch%s%s" % (x.get("codec"), x.get("channels"),
                             (" " + x["language"]) if x.get("language") else "",
                             " commentary" if x.get("commentary") else "") for x in a)))
    s = m.get("subtitles") or []
    parts.append("%d subtitle(s)%s" % (len(s), (" (" + ", ".join(sorted(set(
        "%s/%s" % (x.get("codec"), x.get("language") or "und") for x in s))) + ")") if s else ""))
    parts.append("%d chapter(s)" % ((m.get("chapters") or {}).get("count") or 0))
    parts.append("%d attachment(s)" % len(m.get("attachments") or []))
    return "; ".join(parts)


def hdr_from_event(ev, pre):
    if not ev.get(pre + "_vidx"):
        return None
    d = {
        "kind": none_if(ev.get(pre + "_hdr_kind")),
        "hdr10plus": ev.get(pre + "_hdr10plus") == "1",
        "dolby_vision": ev.get(pre + "_dv") == "1",
        "master_display": none_if(ev.get(pre + "_master_display")),
        "max_cll": none_if(ev.get(pre + "_max_cll")),
    }
    if d["dolby_vision"]:
        d["dv_profile"] = none_if(ev.get(pre + "_dv_profile"))
        d["dv_compat"] = none_if(ev.get(pre + "_dv_compat"))
        d["dv_level"] = none_if(ev.get(pre + "_dv_level"))
        d["dv_el_present"] = {"1": True, "0": False}.get(ev.get(pre + "_dv_el") or "")
    label = d["kind"] or "?"
    if d["hdr10plus"]:
        label += " + HDR10+"
    if d["dolby_vision"]:
        label = "DV profile %s%s + %s" % (d.get("dv_profile") or "?",
                                           ("." + d["dv_compat"]) if d.get("dv_compat") else "", label)
    d["label"] = label
    return d


# ----------------------------------------------------------------------
# Spooled job events -> journal entries
# ----------------------------------------------------------------------

def read_event_tsv(path):
    ev = {}
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.rstrip("\r\n")
            if "\t" in line:
                k, v = line.split("\t", 1)
                ev[k] = v
    return ev


def read_argv(path):
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError:
        return None
    return [a.decode("utf-8", "replace") for a in raw.split(b"\0") if a != b""] or None


def _opt(argv, *names):
    if not argv:
        return None
    for i, a in enumerate(argv[:-1]):
        if a in names:
            return argv[i + 1]
    return None


def _short_x265_params(v):
    if not v:
        return v
    # the per-item scratch paths (HDR10+ JSON) say nothing about the settings
    return re.sub(r"(dhdr10-info=)[^:]*", lambda m: m.group(1) + "<hdr10plus.json>", v)


def sei_parse(sei):
    """x265 settings SEI -> (version, options string, rate control)."""
    if not sei:
        return None, None, None
    m = re.search(r"x265 \(build \d+\) - ([^ ]+)", sei)
    version = m.group(1).split(":")[0] if m else None
    opts = None
    m = re.search(r"options: (.*)$", sei)
    if m:
        opts = m.group(1).strip()
    rc = None
    if opts:
        o = dict(x.split("=", 1) for x in opts.split() if "=" in x)
        if o.get("rc") == "crf":
            rc = "crf %s" % o.get("crf")
        elif o.get("rc") == "abr":
            rc = ("2-pass " if to_int(o.get("stats-read")) and int(o["stats-read"]) >= 2 else "abr ") + \
                 "%s kb/s" % o.get("bitrate")
        elif o.get("rc"):
            rc = o.get("rc")
    return version, opts, rc


def settings_from(ev, spool_dir):
    exp = {k[4:]: v for k, v in ev.items() if k.startswith("exp_")}
    enc = None
    for name in ("cmd_encode", "cmd_2-2"):
        enc = read_argv(os.path.join(spool_dir, name)) or enc
    mux = read_argv(os.path.join(spool_dir, "cmd_mux"))
    s = {}
    mode = exp.get("mode") or ("copy" if exp.get("video") == "copy" else None)
    s["video"] = {"copy": "stream copy (not re-encoded)", "crf": "x265 CRF (single pass)",
                  "abr": "x265 two-pass bitrate"}.get(mode, mode)
    if mode == "crf":
        s["crf"] = to_float(exp.get("crf")) if exp.get("crf") else None
        if exp.get("crf_planned") and exp.get("crf_planned") != exp.get("crf"):
            s["crf_planned"] = to_float(exp.get("crf_planned"))
    if mode == "abr":
        s["bitrate_kbps"] = to_int(exp.get("kbps"))
    if enc:
        s["encoder"] = "libx265" if "libx265" in enc else _opt(enc, "-c:v:0", "-c:v")
        s["x265_preset"] = _opt(enc, "-preset", "-preset:v:0")
        s["x265_tune"] = _opt(enc, "-tune:v:0", "-tune")
        s["x265_params"] = _short_x265_params(_opt(enc, "-x265-params:v:0", "-x265-params"))
        s["pix_fmt"] = _opt(enc, "-pix_fmt:v:0", "-pix_fmt")
        s["video_filter"] = _opt(enc, "-filter:v:0", "-vf")
    version, opts, rc = sei_parse(ev.get("x265_sei"))
    if opts:
        s["x265_settings"] = opts
        s["x265_rate_control_in_stream"] = rc
    s["scaled"] = exp.get("scaled") == "1" if "scaled" in exp else None
    s["dolby_vision_policy"] = exp.get("dv") or None
    if exp.get("dv") == "preserve":
        s["dolby_vision_output"] = "%s%s" % (exp.get("dv_profile") or "?",
                                             ("." + exp["dv_compat"]) if exp.get("dv_compat") else "")
    s["hdr10plus_policy"] = exp.get("hdr10p") or None
    for k, name in (("ceiling_vbytes", "video_ceiling_bytes"), ("floor_vbytes", "video_floor_bytes"),
                    ("est_vbytes", "estimated_video_bytes"), ("qtarget_vbytes", "quality_target_bytes"),
                    ("qmin_vbytes", "quality_min_bytes"), ("qmax_vbytes", "quality_max_bytes")):
        if to_int(exp.get(k)):
            s[name] = to_int(exp[k])
    if exp.get("crf_min") or exp.get("crf_max"):
        s["crf_range"] = [to_float(exp.get("crf_min")), to_float(exp.get("crf_max"))]
    if exp.get("batch_mode"):
        s["season_batch"] = exp["batch_mode"]
    if exp.get("down_mode"):
        s["crf_search"] = exp["down_mode"]
    # audio: what was planned per transcoded track (the verification
    # checked codec / channels / layout / rate against it)
    plans = []
    for p in (exp.get("aplan") or "").split(","):
        f = p.split(":")
        if len(f) >= 5 and f[0].isdigit():
            plans.append({"track": int(f[0]) + 1, "codec": f[1], "channels": to_int(f[2]),
                          "layout": f[3], "sample_rate": to_int(f[4]),
                          "kbps": to_int(f[5]) if len(f) > 5 else None})
    if plans:
        s["audio_transcode"] = plans
    elif "atrans" in exp:
        s["audio"] = "every track copied" if not exp.get("atrans") else "tracks %s transcoded" % exp["atrans"]
    if mux and ev.get("job_type") == "audio":
        s["audio_options"] = ["%s %s" % (mux[i], mux[i + 1]) for i in range(len(mux) - 1)
                              if re.match(r"^-(c|b|filter):a:\d+$", mux[i])]
    return {k: v for k, v in s.items() if v not in (None, "", [], {})}, version


def parse_ops(path):
    if not os.path.exists(path):
        return None
    out = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            p = line.rstrip("\r\n").split("\t")
            if len(p) >= 3:
                out.append({"scope": p[0], "subject": p[1], "action": p[2],
                            "detail": p[3] if len(p) > 3 else "", "basis": "verified"})
    return out


def parse_attempts(s):
    out = []
    for row in (s or "").split(";"):
        f = row.split("|")
        if len(f) >= 4 and f[0]:
            out.append({"crf": to_float(f[0]), "estimated_video_bytes": to_int(f[1]),
                        "actual_video_bytes": to_int(f[2]), "result": f[3] or None,
                        "reason": (f[4] if len(f) > 4 else "") or None})
    return out


def kind_of(ev, output):
    jt = ev.get("job_type")
    if jt == "series":
        return "episode"
    if jt == "movie":
        return "movie"
    return None


def series_of(kind, path):
    if kind != "episode":
        return None
    name = os.path.basename(path or "")
    m = EPISODE_RE.search(name)
    return {"show": os.path.basename(os.path.dirname(path or "")) or None,
            "episode": ("S%02dE%02d" % (int(m.group(1)), int(m.group(2)))) if m else None}


def event_to_entry(spool_dir):
    ev = read_event_tsv(os.path.join(spool_dir, "event.tsv"))
    for k in ("id", "op_id", "time", "output"):
        if not ev.get(k):
            raise ValueError("event without %s" % k)
    if not UUID_RE.match(ev["id"]):
        raise ValueError("bad id %r" % ev["id"])

    def load_probe(name):
        p = os.path.join(spool_dir, name)
        try:
            with open(p, encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            return None

    output = ev["output"]
    src_m = compact_media(load_probe("source.json"), ev.get("input"),
                          to_int(ev.get("source_bytes")), hdr_from_event(ev, "src"))
    out_m = compact_media(load_probe("output.json"), output,
                          to_int(ev.get("output_bytes")), hdr_from_event(ev, "out"))
    settings, x265_version = settings_from(ev, spool_dir)
    tools = {k[5:]: v for k, v in ev.items() if k.startswith("tool_") and v}
    exp = {k[4:]: v for k, v in ev.items() if k.startswith("exp_")}
    # only the tools this operation used
    if exp.get("dv") != "preserve":
        tools.pop("dovi_tool", None)
    if exp.get("hdr10p") != "preserve":
        tools.pop("hdr10plus_tool", None)
    if x265_version:
        tools["x265"] = x265_version
    commit = ev.get("git_commit")
    git = {
        "commit": commit if commit and SHA_RE.match(commit) else None,
        "describe": none_if(ev.get("git_describe")),
        "branch": none_if(ev.get("git_branch")),
        "dirty": {"dirty": True, "clean": False}.get(ev.get("git_tree")),
        "captured": ev.get("git_captured") or None,
    }
    changes = parse_ops(os.path.join(spool_dir, "ops.tsv"))
    op = {
        "op_id": ev["op_id"],
        "type": ev.get("op_type") or "compress",
        "time": ev["time"],
        "recorded": ev.get("recorded"),
        "basis": "recorded by the job that produced the file",
        "job": {"session": ev.get("job_session"), "type": ev.get("job_type"),
                "item": to_int(ev.get("job_item")), "log_dir": ev.get("job_log_dir")},
        "preset": none_if(ev.get("preset")),
        "git": git,
        "tools": tools,
        "settings": settings,
        "source": src_m or {"path": ev.get("input"), "size": to_int(ev.get("source_bytes")),
                            "note": "not probed"},
        "output": out_m or {"path": output, "size": to_int(ev.get("output_bytes")), "note": "not probed"},
        "changes": changes if changes is not None else [],
        "changes_recorded": changes is not None,
        "verification": ev.get("verification") or None,
        "embedded_tags": {"state": ev.get("tags") or None, "ops_summary": ev.get("ops_summary") or None},
    }
    if changes is None:
        op["changes_note"] = "the verification wrote no operation list: what happened to each track is unknown"
    attempts = parse_attempts(ev.get("attempts"))
    if attempts:
        op["crf_attempts"] = attempts
    for k, name in (("over_ceiling", "over_ceiling"), ("below_floor", "below_floor")):
        if ev.get(k) == "1":
            op.setdefault("flags", []).append(name)
    if ev.get("dv_el"):
        op["dolby_vision_enhancement_layer"] = ev["dv_el"]
    if ev.get("chapters_state"):
        op["chapters_state"] = ev["chapters_state"]
    if ev.get("titles_state"):
        op["titles_state"] = ev["titles_state"]
    if to_int(ev.get("final_video_bytes")):
        op["output_video_bytes"] = to_int(ev["final_video_bytes"])
    kind = kind_of(ev, output)
    seg = none_if(ev.get("segment_uid"))
    return {
        "entry": "output",
        "id": ev["id"],
        "op": op,
        "kind": kind,
        "series": series_of(kind, output),
        "parent_id": ev.get("parent_id") if UUID_RE.match(ev.get("parent_id") or "") else None,
        "tags_embedded": ev.get("tags") == "written",
        "file": {"path": output, "name": os.path.basename(output),
                 "size": to_int(ev.get("output_bytes")), "segment_uid": seg},
    }


def cmd_ingest(args, store):
    os.makedirs(store.spool, exist_ok=True)
    names = sorted(n for n in os.listdir(store.spool)
                   if not n.startswith(".") and os.path.isdir(os.path.join(store.spool, n)))
    entries, done, bad = [], [], []
    for n in names:
        d = os.path.join(store.spool, n)
        try:
            entries.append(event_to_entry(d))
            done.append(d)
        except (OSError, ValueError, KeyError) as e:
            bad.append((d, str(e)))
    if entries:
        _, changed = store.commit(entries)
    else:
        changed = []
        with store.locked():
            data = store.load()
            if store.notes and data["records"] is not None:
                # recovered on load (backup / journal): write the repaired manifest back
                store.save(data)
    for d in done:
        shutil.rmtree(d, ignore_errors=True)
    rejected = os.path.join(store.spool, ".rejected")
    for d, why in bad:
        os.makedirs(rejected, exist_ok=True)
        try:
            os.replace(d, os.path.join(rejected, os.path.basename(d)))
        except OSError:
            pass
        eprint("provenance: spooled event %s rejected: %s" % (os.path.basename(d), why))
    for n in store.notes:
        eprint("provenance: " + n)
    if not args.quiet or changed:
        for e in changed:
            print("recorded %s  %s" % (e["id"], e["file"]["path"]))
        if not args.quiet:
            print("%d event(s) applied, %d already in the manifest, %d rejected" %
                  (len(changed), len(entries) - len(changed), len(bad)))
    return 1 if bad else 0


# ----------------------------------------------------------------------
# Existing files: scan / tag / relink
# ----------------------------------------------------------------------

def list_media(paths):
    out = []
    for p in paths:
        q = native(p)
        if os.path.isdir(q):
            for root, dirs, files in os.walk(q, followlinks=True):
                dirs.sort()
                for f in sorted(files):
                    if f.lower().endswith(".mkv"):
                        out.append(os.path.join(root, f))
        elif os.path.isfile(q):
            out.append(q)
        else:
            eprint("not found: %s" % p)
    return out


def global_tags(probe):
    return _tags((probe or {}).get("format") or {})


def segment_uid(path):
    rc, out = run(["mkvmerge", "-J", native(path)], timeout=120)
    if rc not in (0, 1) or not out:
        return None
    try:
        j = json.loads(out)
    except ValueError:
        return None
    return ((j.get("container") or {}).get("properties") or {}).get("segment_uid")


def read_ledger(work):
    """work/logs/compression_tags.tsv rows (the record of every CRF encode
    of earlier versions)."""
    p = os.path.join(native(work), "logs", "compression_tags.tsv")
    rows = []
    if not os.path.exists(p):
        return rows
    with open(p, encoding="utf-8", errors="replace") as f:
        head = None
        for line in f:
            cols = line.rstrip("\r\n").split("\t")
            if head is None:
                head = cols
                continue
            if len(cols) >= len(head):
                rows.append(dict(zip(head, cols)))
    return rows


class Repo:
    """The movie-compresser checkout (work/lib/../..)."""

    def __init__(self, root):
        self.root = root
        self._ok = None
        self._diff_cache = {}

    def git(self, *a, timeout=120):
        return run(["git", "-C", self.root] + list(a), timeout=timeout)

    def ok(self):
        if self._ok is None:
            rc, out = self.git("rev-parse", "--show-toplevel")
            self._ok = rc == 0 and pkey(out.strip()) == pkey(self.root)
        return self._ok

    def head(self):
        rc, out = self.git("rev-parse", "--verify", "-q", "HEAD^{commit}")
        return out.strip() if rc == 0 else None

    def dirty(self):
        rc, out = self.git("status", "--porcelain", "--untracked-files=no")
        return None if rc != 0 else bool(out.strip())

    def resolve(self, ref):
        if not ref:
            return None
        rc, out = self.git("rev-parse", "--verify", "-q", ref + "^{commit}")
        out = out.strip()
        return out if rc == 0 and SHA_RE.match(out) else None

    def has(self, sha):
        return bool(sha) and self.git("cat-file", "-e", sha + "^{commit}")[0] == 0


def recover_history(path, tags, ledger, repo):
    """What can still be known about a file without a provenance record:
    legacy embedded tags of earlier versions, the CRF ledger. Every value
    names its source; nothing is derived from the media itself."""
    fields = {}
    sources = []
    tool = tags.get("COMPRESSION_TOOL")
    ver = tags.get("MOVIE_COMPRESSER_VERSION")
    if tool or ver or tags.get("COMPRESSION_CRF"):
        sources.append("embedded COMPRESSION_* tags (movie-compresser before provenance tracking)")
        if tool:
            fields["tool"] = {"value": tool, "from": "COMPRESSION_TOOL tag"}
        if ver:
            fields["git_describe"] = {"value": ver, "from": "MOVIE_COMPRESSER_VERSION tag"}
            sha = repo.resolve(ver[:-6] if ver.endswith("-dirty") else ver) if repo.ok() and ver != "unknown" else None
            if sha:
                fields["git_commit"] = {"value": sha, "from": "MOVIE_COMPRESSER_VERSION tag, resolved in this checkout"}
            if ver.endswith("-dirty"):
                fields["git_dirty"] = {"value": True, "from": "MOVIE_COMPRESSER_VERSION tag"}
        if tags.get("COMPRESSION_DATE"):
            fields["date"] = {"value": tags["COMPRESSION_DATE"], "from": "COMPRESSION_DATE tag"}
        if tags.get("COMPRESSION_CRF"):
            fields["crf"] = {"value": to_float(tags["COMPRESSION_CRF"]), "from": "COMPRESSION_CRF tag"}
        if tags.get("COMPRESSION_TIER"):
            fields["preset"] = {"value": tags["COMPRESSION_TIER"], "from": "COMPRESSION_TIER tag"}
    by_path = [r for r in ledger if same_path(r.get("output"), path)]
    by_name = [r for r in ledger if os.path.basename(r.get("output") or "") == os.path.basename(path)]
    rows, how = (by_path, "same path") if by_path else (by_name, "same file name only")
    if rows:
        if len({(r.get("crf"), r.get("tier")) for r in rows}) == 1:
            r = rows[-1]
            src = "work/logs/compression_tags.tsv (%s)" % how
            sources.append(src)
            fields.setdefault("crf", {"value": to_float(r.get("crf")), "from": src})
            if none_if(r.get("tier")):
                fields.setdefault("preset", {"value": r["tier"], "from": src})
            fields["ledger_date"] = {"value": r.get("date"), "from": src}
            if none_if(r.get("session")):
                fields["job_session"] = {"value": r["session"], "from": src}
            if none_if(r.get("input")):
                fields["source_path"] = {"value": r["input"], "from": src}
            if to_int(r.get("video_bytes")):
                fields["video_bytes"] = {"value": to_int(r["video_bytes"]), "from": src}
        else:
            sources.append("work/logs/compression_tags.tsv: %d disagreeing rows (%s): ignored" % (len(rows), how))
    return {"fields": fields, "sources": sources}


UNKNOWN_FIELDS = ("git_commit", "date", "preset", "crf", "x265_settings", "tool_versions",
                  "source_properties", "track_operations")


def find_record(data, tags, path, seg):
    recs = data["records"]
    pid = (tags.get("PROVENANCE_ID") or "").strip().lower()
    if pid and pid in recs:
        return recs[pid], "embedded PROVENANCE_ID"
    if seg:
        size = file_size(path)
        for r in recs.values():
            cur = r.get("current") or {}
            if cur.get("segment_uid") and cur["segment_uid"].lower() == seg.lower() and \
                    (cur.get("size") is None or cur.get("size") == size):
                return r, "Matroska segment UID + size"
    return None, None


def describe_file(path, data, ledger, repo):
    probe = ffprobe_json(path)
    tags = global_tags(probe)
    pid = (tags.get("PROVENANCE_ID") or "").strip().lower()
    seg = segment_uid(path)
    rec, how = find_record(data, tags, path, seg)
    info = {"path": path, "size": file_size(path), "segment_uid": seg,
            "embedded": {k: tags[k] for k in TAG_NAMES if k in tags},
            "legacy_tags": {k: tags[k] for k in LEGACY_TAGS if k in tags},
            "media": compact_media(probe, path, file_size(path))}
    if pid and not UUID_RE.match(pid):
        info["problem"] = "PROVENANCE_ID %r is not a valid ID" % pid
        pid = ""
    if rec:
        info["status"] = "recorded" if rec.get("provenance") == "recorded" else rec.get("provenance", "unknown")
        info["record_id"] = rec["id"]
        info["matched_by"] = how
        cur = (rec.get("current") or {}).get("path")
        if not same_path(cur, path):
            info["moved"] = {"record_path": cur, "record_path_exists": os.path.exists(native(cur or ""))}
        if not pid:
            info["tags_missing"] = True
    elif pid:
        info["status"] = "embedded-only"
        info["note"] = "the file carries provenance tags but the manifest has no record of %s" % pid
    else:
        info["status"] = "unknown"
        info["recovered"] = recover_history(path, tags, ledger, repo)
    return info, rec


def _known_unknown(info, rec):
    known, unknown = [], []
    if rec:
        o = rec.get("original") or {}
        if o.get("status") in ("unknown", "recovered"):
            unknown.append("original encode (%s)" % o.get("status"))
            for k, v in sorted(((o.get("recovered") or {}).get("fields") or {}).items()):
                known.append("%s = %s  [%s]" % (k, v.get("value"), v.get("from")))
        else:
            g = o.get("git") or {}
            if g.get("commit"):
                known.append("commit %s%s%s" % (g["commit"], " (dirty tree)" if g.get("dirty") else "",
                                               (" branch " + g["branch"]) if g.get("branch") else ""))
            else:
                unknown.append("Git commit (not available when the job was generated)")
            known.append("processed %s, preset %s, %s" % (o.get("time"), o.get("preset"),
                                                          (o.get("settings") or {}).get("video")))
            if o.get("tools"):
                known.append("tools: " + ", ".join("%s %s" % kv for kv in sorted(o["tools"].items())))
            if o.get("changes_recorded"):
                known.append("%d verified track/metadata operations" % len(o.get("changes") or []))
            else:
                unknown.append("per-track operations (not recorded)")
            if o.get("inherited_from"):
                known.append("video history inherited from record %s" % o["inherited_from"])
        for op in rec.get("operations") or []:
            known.append("later: %s at %s (commit %s)" % (op.get("type"), op.get("time"),
                                                          (op.get("git") or {}).get("commit") or "unknown"))
    elif info.get("status") == "embedded-only":
        e = info["embedded"]
        known.append("embedded: commit %s, time %s, preset %s" % (
            e.get("PROVENANCE_COMMIT"), e.get("PROVENANCE_TIME"), e.get("PROVENANCE_PRESET")))
        if e.get("PROVENANCE_OPS"):
            known.append("embedded operations: " + e["PROVENANCE_OPS"])
        unknown.append("detailed history (manifest record missing: provenance.sh relink recovers "
                       "a record from the embedded tags)")
    else:
        rv = info.get("recovered") or {}
        for k, v in sorted((rv.get("fields") or {}).items()):
            known.append("%s = %s  [%s]" % (k, v.get("value"), v.get("from")))
        have = set((rv.get("fields") or {}).keys())
        for k in UNKNOWN_FIELDS:
            if k == "date" and "ledger_date" in have:
                continue
            if k not in have:
                unknown.append(k)
    return known, unknown


def cmd_scan(args, store, repo):
    data = store.load()
    ledger = read_ledger(args.work)
    files = list_media(args.paths or [args.out])
    results = []
    counts = {}
    for f in files:
        info, rec = describe_file(f, data, ledger, repo)
        info["known"], info["unknown"] = _known_unknown(info, rec)
        results.append(info)
        counts[info["status"]] = counts.get(info["status"], 0) + 1
    seen = {r.get("record_id") for r in results}
    missing = []
    if not args.paths:
        for r in data["records"].values():
            if r.get("status") == "active" and r["id"] not in seen and \
                    not os.path.exists(native((r.get("current") or {}).get("path") or "")):
                missing.append({"id": r["id"], "path": (r.get("current") or {}).get("path")})
    if args.json:
        json.dump({"files": results, "records_missing_on_disk": missing, "counts": counts,
                   "manifest_notes": store.notes}, sys.stdout, indent=1, ensure_ascii=False)
        print()
        return 0
    for n in store.notes:
        print("manifest: " + n)
    for i in results:
        print("== %s" % i["path"])
        st = i["status"]
        line = {"recorded": "provenance recorded", "partial": "provenance partly recorded",
                "recovered": "adopted (history partly recovered)",
                "embedded-only": "embedded provenance tags only (no manifest record)",
                "unknown": "NO provenance: encoding history unknown"}.get(st, st)
        if i.get("record_id"):
            line += " (record %s, matched by %s)" % (i["record_id"], i["matched_by"])
        print("  Provenance: " + line)
        if i.get("moved"):
            print("  Location:   moved/renamed; the manifest says %s%s (provenance.sh relink records the move)"
                  % (i["moved"]["record_path"], "" if not i["moved"]["record_path_exists"] else " (still exists)"))
        if i.get("tags_missing"):
            print("  Tags:       no PROVENANCE_ID in the file (tag write failed earlier; provenance.sh tag adds it)")
        if i.get("problem"):
            print("  Problem:    " + i["problem"])
        for k in i["known"]:
            print("  Known:      " + k)
        for k in i["unknown"]:
            print("  Unknown:    " + k)
        print("  Media now:  " + media_line(i.get("media")))
    for m in missing:
        print("== record %s: file missing (%s)" % (m["id"], m["path"]))
    print()
    print("%d file(s): %s" % (len(results), ", ".join("%s %d" % kv for kv in sorted(counts.items())) or "none"))
    return 0


def _adopt_op(repo, what, tagged):
    head = repo.head() if repo.ok() else None
    return {
        "op_id": "tag-%s-%s" % (datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ"),
                                uuid.uuid4().hex[:8]),
        "type": "provenance-tag",
        "time": utcnow(),
        "basis": "provenance.sh tag (tags only, media untouched)",
        "note": what,
        "git": {"commit": head, "dirty": repo.dirty() if head else None,
                "role": "the checkout that added the ID tag; it did NOT process the media"},
        "tools": {k: v for k, v in tool_versions_now(("mkvtoolnix",)).items()},
        "tags_written": tagged,
    }


def tool_versions_now(which=("ffmpeg", "mkvtoolnix")):
    out = {}
    if "ffmpeg" in which:
        rc, s = run(["ffmpeg", "-hide_banner", "-version"], timeout=30)
        m = re.match(r"ffmpeg version (\S+)", s or "")
        if m:
            out["ffmpeg"] = m.group(1)
    if "mkvtoolnix" in which:
        rc, s = run(["mkvmerge", "--version"], timeout=30)
        m = re.match(r"mkvmerge v?(\S+)", s or "")
        if m:
            out["mkvtoolnix"] = m.group(1)
    return out


def write_tags(path, pairs):
    """PROVENANCE_* global tags via encode_common.sh mkv_set_global_tags
    (the job's writer: every other tag kept and read back)."""
    bash = native(os.environ.get("PROV_BASH") or "") or shutil.which("bash")
    if not bash:
        return 127, "bash not found"
    tmp = tempfile.mkdtemp(prefix="provenance-tag-")
    script = ('source "$1/ui.sh" >/dev/null 2>&1; source "$1/encode_common.sh" >/dev/null 2>&1 || exit 9; '
              'f="$2"; d="$3"; shift 3; mkv_set_global_tags "$f" "$d" "$PROVENANCE_TAG_NAMES" "$@"')
    try:
        p = subprocess.run([bash, "-c", script, "_", LIB_DIR, path, tmp] +
                           ["%s=%s" % kv for kv in pairs],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True,
                           timeout=600)
        rc, out = p.returncode, p.stdout
        try:
            with open(os.path.join(tmp, "mkvpropedit_global_tags.log"), encoding="utf-8", errors="replace") as f:
                out += f.read()
        except OSError:
            pass
    except (OSError, subprocess.SubprocessError) as e:
        rc, out = 127, str(e)
    shutil.rmtree(tmp, ignore_errors=True)
    return rc, out


def cmd_tag(args, store, repo):
    if not args.paths:
        eprint("tag: name the files or directories to tag (nothing is tagged implicitly)")
        return 2
    data = store.load()
    ledger = read_ledger(args.work)
    plan = []
    for f in list_media(args.paths):
        info, rec = describe_file(f, data, ledger, repo)
        if info["embedded"].get("PROVENANCE_ID") and info.get("status") != "unknown":
            print("skip  %s  (already has PROVENANCE_ID %s)" % (f, info["embedded"]["PROVENANCE_ID"]))
            continue
        if rec:
            rid, status = rec["id"], rec.get("provenance", "unknown")
            what = "ID of the existing record %s re-embedded (matched by %s)" % (rid, info["matched_by"])
        else:
            rid = str(uuid.uuid4())
            rv = info.get("recovered") or {}
            status = "recovered" if rv.get("fields") else "unknown"
            what = "existing file adopted: history %s" % status
        pairs = [("PROVENANCE_TOOL", TOOL), ("PROVENANCE_ID", rid), ("PROVENANCE_STATUS", status)]
        # a commit is only ever embedded when it is the recorded producer
        if rec and (rec.get("original") or {}).get("git", {}).get("commit"):
            o = rec["original"]
            pairs += [("PROVENANCE_COMMIT", o["git"]["commit"]),
                      ("PROVENANCE_TREE", {True: "dirty", False: "clean"}.get(o["git"].get("dirty"), "unknown"))]
            if o.get("time"):
                pairs.append(("PROVENANCE_TIME", o["time"]))
            if o.get("preset"):
                pairs.append(("PROVENANCE_PRESET", o["preset"]))
            if (o.get("embedded_tags") or {}).get("ops_summary"):
                pairs.append(("PROVENANCE_OPS", o["embedded_tags"]["ops_summary"]))
        plan.append((f, rid, rec, info, what, pairs))
        print("%s  %s  ->  %s" % ("would tag" if args.dry_run else "tag", f,
                                  " ".join("%s=%s" % kv for kv in pairs)))
    if args.dry_run or not plan:
        print("%d file(s) %s." % (len(plan), "would be tagged (dry run: nothing written)" if args.dry_run else "to tag"))
        return 0
    entries = []
    failed = 0
    for f, rid, rec, info, what, pairs in plan:
        rc, out = write_tags(f, pairs)
        if rc != 0:
            failed += 1
            print("FAILED  %s  (exit %d; file unchanged)" % (f, rc))
            if args.verbose:
                print(out)
            continue
        size = file_size(f)
        entry = {"entry": "adopt", "id": rid, "op": _adopt_op(repo, what, True), "tags_embedded": True,
                 "file": {"path": f, "name": os.path.basename(f), "size": size,
                          "segment_uid": info.get("segment_uid")}}
        if not rec:
            entry["recovered"] = info.get("recovered")
            entry["media"] = info.get("media")
            kind = "episode" if EPISODE_RE.search(os.path.basename(f)) else None
            entry["kind"] = kind
            entry["series"] = series_of(kind, f)
        entries.append(entry)
        print("tagged  %s  PROVENANCE_ID=%s" % (f, rid))
    if entries:
        store.commit(entries)
    print("%d tagged, %d failed" % (len(entries), failed))
    return 1 if failed else 0


def cmd_relink(args, store, repo):
    data = store.load()
    files = list_media(args.paths or [args.out])
    entries = []
    for f in files:
        probe = ffprobe_json(f)
        tags = global_tags(probe)
        pid = (tags.get("PROVENANCE_ID") or "").strip().lower()
        if not UUID_RE.match(pid):
            continue
        rec = data["records"].get(pid)
        now = utcnow()
        if rec is None:
            # the file knows its provenance, the manifest lost it: a record
            # from the embedded tags (marked as such)
            fields = {}
            for k, name in (("PROVENANCE_COMMIT", "git_commit"), ("PROVENANCE_TREE", "git_tree"),
                            ("PROVENANCE_TIME", "time"), ("PROVENANCE_PRESET", "preset"),
                            ("PROVENANCE_OPS", "operations_summary"), ("PROVENANCE_PARENT", "parent_id")):
                if tags.get(k):
                    fields[name] = {"value": tags[k], "from": "embedded %s tag" % k}
            e = {"entry": "adopt", "id": pid, "tags_embedded": True,
                 "op": dict(_adopt_op(repo, "record recovered from the embedded provenance tags", False),
                            type="record-recovery", basis="provenance.sh relink (manifest only)"),
                 "file": {"path": f, "name": os.path.basename(f), "size": file_size(f),
                          "segment_uid": segment_uid(f)},
                 "recovered": {"fields": fields, "sources": ["embedded PROVENANCE_* tags"]},
                 "media": compact_media(probe, f, file_size(f))}
            entries.append(e)
            print("%s  %s  (record %s recovered from the embedded tags)" %
                  ("would recover" if args.dry_run else "recover", f, pid))
            continue
        cur = (rec.get("current") or {}).get("path")
        if same_path(cur, f):
            continue
        if cur and os.path.exists(native(cur)):
            other = global_tags(ffprobe_json(cur)).get("PROVENANCE_ID", "").lower()
            if other == pid:
                print("CONFLICT  %s and %s both carry %s (a copy?): not relinked" % (cur, f, pid))
                continue
        entries.append({"entry": "relocate", "id": pid, "op_id": "relocate-%s" % uuid.uuid4().hex[:12],
                        "time": now, "from": cur, "to": f, "size": file_size(f),
                        "reason": "renamed" if os.path.dirname(pkey(cur or "")) == os.path.dirname(pkey(f)) else "moved"})
        print("%s  %s -> %s" % ("would relink" if args.dry_run else "relink", cur, f))
    if args.dry_run:
        print("%d change(s) (dry run: manifest not written)." % len(entries))
        return 0
    if entries:
        store.commit(entries)
    print("%d change(s) recorded." % len(entries))
    return 0


# ----------------------------------------------------------------------
# Version comparison
# ----------------------------------------------------------------------

# area of a changed function / file. Areas: encoder, encoder:movie,
# encoder:series, hdr, audio, streams (track mapping: audio + subtitles),
# subtitle, metadata (titles / tags / chapters: fixable without encoding),
# verification (checks only: cannot change an existing file), none
# (orchestration, reporting, tests, docs), review (unmapped: manual review)
FILE_AREAS = [
    (r"^work/tests/", "none"), (r"\.md$", "none"), (r"^(progress-check|verify|audio_titles|compress_menu)\.sh$", "none"),
    (r"^window_tagger\.py$", "none"), (r"^work/lib/mkv-property-handler/", "none"),
    (r"^work/lib/(ui|fs_guard|naming|provenance)\.(sh|py)$", "none"), (r"^\.git", "none"),
    (r"^(in|out)/", "none"), (r"^work/lib/media_stats\.sh$", "metadata"),
    (r"^work/lib/bitrate\.sh$", "encoder"), (r"^work/movie_compress\.sh$", "encoder:movie"),
    (r"^work/series_compress\.sh$", "encoder:series"), (r"^audio_compress_menu\.sh$", "audio"),
    (r"^work/lib/audio_plan\.sh$", "audio"),
]
FUNC_AREAS = {
    "work/lib/encode_common.sh": [
        (r"^(audio_title_|_audio_title|audio_std_title|audio_desc_|_audio_desc|audio_lang_name|audio_codec_name|"
         r"audio_channel_notation|audio_measured_kbps|video_.*title|_video_title|video_codec_label|"
         r"video_resolution_label|video_hdr_label|video_crf_label|video_stream_crf|video_pix_bits|"
         r"mkv_std_track_titles|mkv_write_track_titles|_title_join|codec_title_label|_audio_rows|"
         r"audio_title|_audio_title_rest)", "metadata"),
        (r"^(audio_|_audio|ac3_|encoder_codec)", "audio"),
        (r"^(x265_color_params|color_output_args|source_video_tag_args)$", "hdr"),
        (r"^(crf_|_crf|base_|_base|libx265_has_option|downscale_1080p_dims|emit_encode_item|"
         r"_emit_final_encode|_emit_x265_lines|emit_copy_item|_encoded_size|X265_)", "encoder"),
        (r"^(build_stream_map)$", "streams"),
        (r"^(mkv_subtitle_action|movtext_|mp4_handler_is_name)", "subtitle"),
        (r"^(matroska_mux_args|emit_part_and_covers|chapter_notes|mkv_set_compression_tags|"
         r"_compression_tags|compression_|mkv_global_tag_values|_xml_escape|COMPRESSION_|mkv_set_global_tags|"
         r"_mkv_write_global_tags|_mkv_tags_arg|provenance_strip_args|PROVENANCE_|refresh_mkv_stats|"
         r"stale_stats_args)", "metadata"),
        (r"^(next_tmux_session|cleanup_finished_jobs|output_|path_taken|unique_output_path|"
         r"resolve_output_conflict|start_job|emit_job_header|emit_job_footer|emit_failed_item|"
         r"actual_file_gib|compresser_|_compresser|compression_date_now|mkv_identify_tracks|"
         r"_mkv_codec_ok|mkv_track_map|_sig_crf|crf_attempt_leftovers)", "none"),
    ],
    "work/lib/hdr_dovi.sh": [
        (r"^(item_verify_output|dv_verify_rpu|_meta_load|_field|_flag_seq|_codec_label|"
         r"_audio_payload_md5|_rep|_vop|_hdr_save|_cover_default|MS)$", "verification"),
        (r"^(hdr_tools_report|dv_detect_report|hdr_policy_summary|hdr_policy_short|hdr_find_tool|"
         r"hdr_tools_detect|_hdr_tools_globals_set|HDR_TOOLS_DETECTED)$", "none"),
        (r".", "hdr"),
    ],
    "work/lib/media_probe.sh": [
        (r"^(probe_hdr|hdr_)", "hdr"),
        (r"^(discover_paths|_discovery|video_files_in_dir|media_files_recursive|series_dirs|file_bytes|"
         r"media_signature|x265_rate_control|x265_sei_options|compression_|format_title|stream_tag|"
         r"chapter_xml_summary|chapter_xml_describe|chapter_xml_same|chapter_xml_canon)", "none"),
        (r"^(mkv_chapters_xml|chapter_meta|format_start_time|mkv_segment_uids)$", "metadata"),
    ],
    "work/lib/job_runtime.sh": [
        (r"^(item_crf_encode|job_crf_batch|_keep_accepted|_drop_attempt|item_attempt_|_down_threshold|"
         r"item_video_bytes|_crf_step_ratio|item_actual_|job_batch_add|_batch|_bceil|_season|"
         r"_median_bytes|_mbps_of|item_retry_enabled|attempt_line|item_rows_final|item_run)", "encoder"),
        (r"^(item_restore_mkv_chapters|item_add_cover|item_tag_compression|item_finalize_titles|"
         r"item_title_)", "metadata"),
        (r"^(item_succeeded|item_part_complete|item_failed|item_keep_completed|job_|item_begin|"
         r"item_expect|item_step|report_output_stats|quality_report_lines|crf_log_prepare|"
         r"record_crf_estimate|item_tmp_drop_intermediates|_gib|_RS|CRF_LOG_HEADER)", "none"),
    ],
    "work/lib/policy.sh": [
        (r"^(_audio_menu|audio_menu_)", "audio"),
        (r"^(movie_policy_line|audio_copy_policy_lines|movie_video_policy_lines|crf_policy_lines|"
         r"crf_analysis_lines|series_crf_analysis_lines|policy_retired_note|series_ceiling_text|"
         r"quality_band_text|quality_pick_text|base_range_text)", "none"),
        (r".", "encoder"),
    ],
}
FUNC_NAME_RE = re.compile(r"^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*(?:\(\)|=)")


def _area_for(path, func, changed_lines):
    if changed_lines and all(re.match(r"^\s*(#.*)?$", l) for l in changed_lines):
        return "none"   # comments / blank lines only
    for rx, area in FILE_AREAS:
        if re.search(rx, path):
            return area
    if path == "work/lib/compress.conf":
        names = set()
        for l in changed_lines:
            m = re.match(r"^\s*([A-Z][A-Z0-9_]*)=", l)
            if m:
                names.add(m.group(1))
        if not names:
            return "none"
        return "audio" if all(n.startswith("AUDIO_") for n in names) else "encoder"
    for rx, area in FUNC_AREAS.get(path, []):
        if func and re.search(rx, func):
            return area
    return "review"


class ChangeAnalyzer:
    def __init__(self, repo):
        self.repo = repo
        self.cache = {}

    def changes_since(self, commit):
        """[(path, function, area)] between COMMIT and HEAD, or None when
        Git cannot tell."""
        if commit in self.cache:
            return self.cache[commit]
        rc, out = self.repo.git("diff", "-U0", "--no-color", "--no-ext-diff", "--no-renames",
                                commit, "HEAD", "--", ".", timeout=300)
        if rc != 0:
            self.cache[commit] = None
            return None
        res = []
        path = None
        hunk = None

        def flush():
            if path and hunk is not None:
                funcs = set(hunk["funcs"]) or {hunk["head"]}
                for fn in funcs:
                    res.append((path, fn, _area_for(path, fn, hunk["lines"])))

        for line in out.splitlines():
            if line.startswith("diff --git "):
                flush()
                hunk = None
                m = re.match(r"diff --git a/(.*) b/(.*)$", line)
                path = m.group(2) if m else None
            elif line.startswith("@@"):
                flush()
                m = re.match(r"@@ [^@]* @@ ?(.*)$", line)
                ctx = m.group(1) if m else ""
                fm = FUNC_NAME_RE.match(ctx)
                hunk = {"head": fm.group(1) if fm else None, "funcs": [], "lines": []}
            elif hunk is not None and line[:1] in "+-" and not line.startswith(("+++", "---")):
                body = line[1:]
                hunk["lines"].append(body)
                fm = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*\(\)", body)
                if fm:
                    hunk["funcs"].append(fm.group(1))
            elif line.startswith(("Binary files", "new file", "deleted file")) and path and hunk is None:
                res.append((path, None, _area_for(path, None, ["x"])))
        flush()
        self.cache[commit] = res
        return res


def _relevant_areas(op, rec):
    """Areas whose changes could matter for this operation of this file."""
    t = op.get("type")
    areas = {"review"}
    if t == "compress" or t == "stream-copy":
        areas |= {"encoder", "streams"}
        kind = rec.get("kind")
        if kind in ("movie", "unknown", None):
            areas.add("encoder:movie")
        if kind in ("episode", "unknown", None):
            areas.add("encoder:series")
        src = op.get("source") or {}
        v = (src.get("video") or [{}])[0] if src.get("video") else {}
        dr = v.get("dynamic_range") or {}
        if not dr or dr.get("kind") != "SDR" or dr.get("dolby_vision") or dr.get("hdr10plus"):
            areas.add("hdr")
        subs = src.get("subtitles")
        if subs is None or subs:
            areas.add("subtitle")
    elif t in ("audio-compress", "remux"):
        areas |= {"audio", "streams", "subtitle"}
    return areas


SEVERITY = {"current": 0, "older-unaffected": 1, "unknown": 2, "manual-review": 3, "potentially-affected": 4}
LABEL = {"current": "Current", "older-unaffected": "Older version, no relevant processing changes",
         "potentially-affected": "Potentially affected by changed encoder/HDR/audio/subtitle logic",
         "manual-review": "Manual review (impact cannot be determined reliably)",
         "unknown": "Unknown provenance"}


def classify_record(rec, repo, analyzer, head):
    res = {"id": rec["id"], "path": (rec.get("current") or {}).get("path"), "kind": rec.get("kind"),
           "class": None, "reasons": [], "notes": [], "commits": []}
    ops = []
    orig = rec.get("original") or {}
    if orig.get("status") in ("unknown", "recovered") or not orig.get("git"):
        res["class"] = "unknown"
        res["reasons"].append("how the video was encoded is not recorded (%s)" % (orig.get("status") or "no record"))
        rv = ((orig.get("recovered") or {}).get("fields") or {}).get("git_commit")
        if rv:
            res["notes"].append("a legacy tag names commit %s (%s); not used as a recorded version" %
                                (rv.get("value"), rv.get("from")))
    else:
        ops.append(orig)
    ops += [o for o in rec.get("operations") or [] if o.get("type") in PROCESSING_OPS and o is not orig]
    worst = res["class"]
    for op in ops:
        g = op.get("git") or {}
        c = g.get("commit")
        res["commits"].append({"op": op.get("type"), "time": op.get("time"), "commit": c, "dirty": g.get("dirty")})
        if not c:
            cls, why = "manual-review", "%s at %s: Git commit not recorded" % (op.get("type"), op.get("time"))
        elif not repo.ok():
            cls, why = "manual-review", "this copy of the compressor is not a Git checkout: history unavailable"
        elif not repo.has(c):
            cls, why = "manual-review", "%s: commit %s is not in this repository (rebased / other clone?)" % (op.get("type"), c[:12])
        else:
            changes = analyzer.changes_since(c) if c != head else []
            if changes is None:
                cls, why = "manual-review", "git diff %s..HEAD failed" % c[:12]
            else:
                rel = _relevant_areas(op, rec)
                hit = sorted({(p, f or "-", a) for p, f, a in changes if a in rel and a != "review"})
                rev = sorted({(p, f or "-") for p, f, a in changes if a == "review"})
                info = sorted({(p, f or "-", a) for p, f, a in changes if a in ("metadata", "verification")})
                if g.get("dirty"):
                    cls = "manual-review"
                    why = "%s ran from a checkout with uncommitted changes (%s): what differed is unknown" % (op.get("type"), c[:12])
                elif hit:
                    cls = "potentially-affected"
                    why = "%s (%s): changed since: %s" % (op.get("type"), c[:12], "; ".join(
                        "%s %s [%s]" % h for h in hit[:12]) + (" ..." if len(hit) > 12 else ""))
                elif rev:
                    cls = "manual-review"
                    why = "%s (%s): unclassified changes: %s" % (op.get("type"), c[:12], "; ".join(
                        "%s %s" % r for r in rev[:12]) + (" ..." if len(rev) > 12 else ""))
                elif c == head:
                    cls, why = "current", "%s: processed by the current commit" % op.get("type")
                else:
                    cls = "older-unaffected"
                    why = "%s (%s): older commit; no change in the logic relevant to this file" % (op.get("type"), c[:12])
                if info and cls in ("older-unaffected", "current", "potentially-affected", "manual-review"):
                    res["notes"].append("metadata / verification changes since %s (no re-encode needed for these; "
                                        "verify.sh Validate + update refreshes titles/tags): %s" % (
                                            c[:12], ", ".join(sorted({"%s %s" % (p, f) for p, f, a in info})[:8])))
        res["reasons"].append(why)
        if worst is None or SEVERITY[cls] > SEVERITY[worst]:
            worst = cls
    res["class"] = worst or "unknown"
    return res


def cmd_compare(args, store, repo):
    data = store.load()
    head = repo.head() if repo.ok() else None
    analyzer = ChangeAnalyzer(repo)
    targets = []
    if args.paths:
        ledger = read_ledger(args.work)
        for f in list_media(args.paths):
            info, rec = describe_file(f, data, ledger, repo)
            if rec:
                targets.append(rec)
            else:
                targets.append({"id": None, "current": {"path": f}, "original": {"status": "unknown"},
                                "_embedded": info["embedded"]})
    else:
        targets = [r for r in data["records"].values() if r.get("status") == "active"]
    results = []
    for rec in targets:
        if rec.get("id") is None:
            r = {"id": None, "path": rec["current"]["path"], "class": "unknown",
                 "reasons": ["no provenance record" + (" (embedded tags only: provenance.sh relink)"
                                                       if rec.get("_embedded") else "")],
                 "notes": [], "commits": []}
        else:
            r = classify_record(rec, repo, analyzer, head)
        results.append(r)
    dirty = repo.dirty() if repo.ok() else None
    if args.json:
        json.dump({"head": head, "head_dirty": dirty, "files": results}, sys.stdout, indent=1, ensure_ascii=False)
        print()
        return 0
    print("Current checkout: %s%s" % (head or "not a Git checkout",
                                     " (uncommitted changes: not part of any comparison)" if dirty else ""))
    counts = {}
    for r in sorted(results, key=lambda x: (-SEVERITY[x["class"]], x["path"] or "")):
        counts[r["class"]] = counts.get(r["class"], 0) + 1
        print("== %s" % r["path"])
        print("  %s%s" % (LABEL[r["class"]], ("  [record %s]" % r["id"]) if r["id"] else ""))
        for x in r["reasons"]:
            print("    - " + x)
        for x in r["notes"]:
            print("    note: " + x)
    print()
    print("Nothing is re-encoded or recommended for re-encoding automatically: 'potentially affected' "
          "and 'manual review' only mean the changed logic should be looked at for these files.")
    print(", ".join("%s: %d" % (LABEL[k], counts[k]) for k in sorted(counts, key=lambda k: SEVERITY[k])) or "no files")
    return 0


def cmd_show(args, store, repo):
    data = store.load()
    key = args.target
    rec = data["records"].get(key.lower())
    if rec is None:
        probe = ffprobe_json(key) if os.path.exists(native(key)) else None
        rec, _ = find_record(data, global_tags(probe), key, segment_uid(key) if probe else None)
        if rec is None:
            for r in data["records"].values():
                if same_path((r.get("current") or {}).get("path"), key):
                    rec = r
    if rec is None:
        eprint("no record for %s" % key)
        return 1
    json.dump(rec, sys.stdout, indent=1, ensure_ascii=False)
    print()
    return 0


def cmd_rebuild(args, store, repo):
    with store.locked():
        data = store.empty()
        n = 0
        for e in store.journal_entries():
            if apply_entry(data, e):
                n += 1
        if args.dry_run:
            print("%d journal entries -> %d records (dry run: manifest not written)" % (n, len(data["records"])))
            return 0
        store.save(data)
    print("manifest rebuilt: %d journal entries -> %d records" % (n, len(data["records"])))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="provenance.sh", description=__doc__.split("\n")[0])
    ap.add_argument("--work", default=os.path.dirname(LIB_DIR), help="the compressor's work directory")
    ap.add_argument("--out", default=None, help="output directory (default: WORK/../out)")
    ap.add_argument("--manifest-dir", default=os.environ.get("PROVENANCE_DIR"),
                    help="manifest directory (default: WORK/logs/provenance)")
    sub = ap.add_subparsers(dest="cmd")
    p = sub.add_parser("ingest", help="merge spooled job events into the manifest")
    p.add_argument("--quiet", action="store_true")
    p = sub.add_parser("scan", help="report provenance of existing files (read-only)")
    p.add_argument("paths", nargs="*")
    p.add_argument("--json", action="store_true")
    p = sub.add_parser("tag", help="add provenance tags to files without them (no re-encode)")
    p.add_argument("paths", nargs="*")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--verbose", action="store_true")
    p = sub.add_parser("relink", help="record moved / renamed files (manifest only)")
    p.add_argument("paths", nargs="*")
    p.add_argument("--dry-run", action="store_true")
    p = sub.add_parser("compare", help="compare recorded compressor versions with this checkout")
    p.add_argument("paths", nargs="*")
    p.add_argument("--json", action="store_true")
    p = sub.add_parser("show", help="print one record (ID or file)")
    p.add_argument("target")
    p = sub.add_parser("rebuild", help="rebuild the manifest from the journal")
    p.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)
    if not args.cmd:
        ap.print_help()
        return 2
    args.work = native(args.work)
    if args.out is None:
        args.out = os.path.join(os.path.dirname(os.path.abspath(args.work)), "out")
    store = Store(native(args.manifest_dir) if args.manifest_dir else os.path.join(args.work, "logs", "provenance"))
    repo = Repo(os.path.dirname(os.path.dirname(LIB_DIR)))
    try:
        return {"ingest": lambda: cmd_ingest(args, store),
                "scan": lambda: cmd_scan(args, store, repo),
                "tag": lambda: cmd_tag(args, store, repo),
                "relink": lambda: cmd_relink(args, store, repo),
                "compare": lambda: cmd_compare(args, store, repo),
                "show": lambda: cmd_show(args, store, repo),
                "rebuild": lambda: cmd_rebuild(args, store, repo)}[args.cmd]()
    except RuntimeError as e:
        eprint("provenance: %s" % e)
        return 3


if __name__ == "__main__":
    sys.exit(main())
