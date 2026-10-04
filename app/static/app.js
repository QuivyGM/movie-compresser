"use strict";

// ---------- helpers ----------

function el(tag, attrs = {}, ...children) {
  const n = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v === null || v === undefined || v === false) continue;
    if (k === "class") n.className = v;
    else if (k.startsWith("on")) n.addEventListener(k.slice(2), v);
    else if (k === "value") n.value = v;
    else n.setAttribute(k, v === true ? "" : v);
  }
  for (const c of children.flat()) {
    if (c === null || c === undefined || c === false) continue;
    n.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return n;
}

async function api(method, url, body) {
  const opts = { method, headers: {} };
  if (body !== undefined) {
    opts.headers["Content-Type"] = "application/json";
    opts.body = JSON.stringify(body);
  }
  const r = await fetch(url, opts);
  let data = null;
  try { data = await r.json(); } catch { /* empty body */ }
  if (!r.ok) {
    const e = new Error((data && (data.error || data.detail && JSON.stringify(data.detail))) || `HTTP ${r.status}`);
    e.status = r.status;
    e.data = data;
    throw e;
  }
  return data;
}

const qs = (o) => new URLSearchParams(o).toString();
const DASH = "—";
const GiB = 2 ** 30, MiB = 2 ** 20, KiB = 1024;

function fmtSize(b) {
  if (b === null || b === undefined) return DASH;
  if (b >= GiB) return (b / GiB).toFixed(2) + " GiB";
  if (b >= MiB) return (b / MiB).toFixed(1) + " MiB";
  if (b >= KiB) return (b / KiB).toFixed(1) + " KiB";
  return b + " B";
}
function fmtRate(bps) {
  if (bps === null || bps === undefined) return DASH;
  return (bps / 1e6).toFixed(2) + " Mb/s";
}
function fmtSpeed(Bps) {
  if (Bps === null || Bps === undefined) return DASH;
  return (Bps / MiB).toFixed(1) + " MiB/s";
}
function fmtDur(s) {
  if (s === null || s === undefined) return DASH;
  s = Math.round(s);
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
  return `${h}:${String(m).padStart(2, "0")}:${String(sec).padStart(2, "0")}`;
}
function fmtTime(t) {
  if (!t) return DASH;
  const d = new Date(t * 1000);
  const p = (x) => String(x).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
}
function fmtDurPrecise(s) {
  if (s === null || s === undefined) return DASH;
  return s < 60 ? s.toFixed(2) + " s" : fmtDur(s);
}
function durTitle(s) {
  if (s.duration_source === "stream") return "Measured: last packet end − first packet pts";
  if (s.duration_source === "container") return "Container duration (stream duration unavailable or < 1 s)";
  return null;
}
const v = (x) => (x === null || x === undefined || x === "" ? DASH : x);

const store = {
  get(k, d) { try { const s = localStorage.getItem(k); return s ? JSON.parse(s) : d; } catch { return d; } },
  set(k, val) { try { localStorage.setItem(k, JSON.stringify(val)); } catch { /* ignore */ } },
};

// ---------- background probe queue (limits concurrent requests so the UI stays responsive) ----------

const probeQueue = { jobs: [], active: 0, limit: 4 };

function enqueueProbe(job) {
  probeQueue.jobs.push(job);
  pumpProbes();
}
function pumpProbes() {
  while (probeQueue.active < probeQueue.limit && probeQueue.jobs.length) {
    const job = probeQueue.jobs.shift();
    if (job.pane.gen !== job.gen) continue; // pane navigated away
    probeQueue.active++;
    job.run().finally(() => { probeQueue.active--; pumpProbes(); });
  }
}

// ---------- state ----------

let LOCATIONS = [];
let LOCAL_FFPROBE = null; // {ok, path, version|error} from /api/status

// Local probing is disabled (instead of failing file by file) when the local ffprobe is unusable.
function probesEnabled(location) {
  return location !== "Local" || !LOCAL_FFPROBE || LOCAL_FFPROBE.ok;
}
const panes = [];
let selection = null; // {pane, entry}

// ---------- panes ----------

const COLUMNS = [
  { key: "name", label: "Name", get: (e) => e.name.toLowerCase() },
  { key: "size", label: "Size", num: true, get: (e) => (e.type === "folder" ? e.folder?.size : e.size) ?? -1 },
  { key: "res", label: "Resolution", get: (e) => resPixels(e.media?.resolution) },
  { key: "vcodec", label: "Video codec", get: (e) => e.media?.video_codec ?? "" },
  { key: "vbr", label: "Video bitrate", num: true, get: (e) => e.media?.video_bitrate ?? -1 },
  { key: "acodec", label: "Audio codec", get: (e) => e.media?.main_audio_codec ?? "" },
  { key: "abr", label: "Audio bitrate", num: true, get: (e) => e.media?.main_audio_bitrate ?? -1 },
  { key: "dur", label: "Duration", num: true, get: (e) => e.media?.duration ?? -1 },
  { key: "mtime", label: "Modified", get: (e) => e.mtime ?? 0 },
];
function resPixels(r) {
  if (!r) return -1;
  const [w, h] = r.split("x").map(Number);
  return w * h;
}

class Pane {
  constructor(location, path) {
    this.location = location;
    this.path = path;
    this.parent = null;
    this.entries = [];
    this.sort = { key: "name", desc: false };
    this.gen = 0;
    this.selectedPath = null;
    this.build();
    panes.push(this);
    document.getElementById("panes").append(this.root);
    this.load();
  }

  build() {
    this.locSel = el("select", { onchange: () => { this.location = this.locSel.value; this.navigate(""); } },
      LOCATIONS.map((l) => el("option", { value: l.name }, l.name)));
    this.locSel.value = this.location;
    this.pathInput = el("input", { class: "path", spellcheck: "false",
      onkeydown: (ev) => { if (ev.key === "Enter") this.navigate(this.pathInput.value.trim()); } });
    this.testBtn = el("button", { title: "Test connection", onclick: () => this.test() }, "Test");
    this.status = el("div", { class: "pane-status muted" });
    this.thead = el("tr");
    this.tbody = el("tbody");
    this.root = el("div", { class: "pane", onmousedown: () => setActivePane(this) },
      el("div", { class: "pane-bar" },
        this.locSel, this.testBtn,
        el("button", { title: "Up", onclick: () => this.up() }, "↑ Up"),
        this.pathInput,
        el("button", { title: "Refresh", onclick: () => this.load() }, "⟳ Refresh"),
        el("button", { title: "Close pane", onclick: () => this.close() }, "×")),
      this.status,
      el("div", { class: "table-wrap" }, el("table", { class: "grid" }, el("thead", {}, this.thead), this.tbody)));
    this.renderHead();
  }

  setStatus(text, cls = "muted") {
    this.status.className = "pane-status " + cls;
    this.status.textContent = text;
  }

  async test() {
    this.testBtn.disabled = true;
    this.setStatus(`Testing ${this.location}…`);
    try {
      const r = await api("POST", `/api/locations/${encodeURIComponent(this.location)}/test`);
      if (r.ok) this.setStatus(r.local ? "Local filesystem" :
        `Connected: latency ${r.latency_ms} ms (connect ${r.connect_ms ?? 0} ms), home ${r.home}`, "ok");
      else this.setStatus(`Failed: ${r.error}`, "err");
    } catch (e) {
      this.setStatus(`Failed: ${e.message}`, "err");
    } finally {
      this.testBtn.disabled = false;
    }
  }

  navigate(path) {
    this.path = path;
    this.load();
  }

  up() {
    if (this.parent === null || this.parent === undefined) return;
    this.navigate(this.parent);
  }

  close() {
    if (panes.length <= 1) return;
    panes.splice(panes.indexOf(this), 1);
    this.gen++;
    this.root.remove();
    if (selection?.pane === this) setSelection(null);
    savePanes();
    refreshSendTargets();
  }

  async load() {
    const gen = ++this.gen;
    this.pathInput.value = this.path;
    this.setStatus("Loading…");
    savePanes();
    try {
      const data = await api("GET", "/api/list?" + qs({ location: this.location, path: this.path }));
      if (gen !== this.gen) return;
      this.path = data.path;
      this.parent = data.parent;
      this.entries = data.entries;
      this.pathInput.value = this.path || "";
      const nf = this.entries.filter((e) => e.type === "file").length;
      const nd = this.entries.length - nf;
      this.setStatus(this.path ? `${nd} folders, ${nf} files` : "Configured roots");
      this.render();
      this.queueBackground(gen);
      savePanes();
      refreshSendTargets();
    } catch (e) {
      if (gen !== this.gen) return;
      this.entries = [];
      this.render();
      this.setStatus(`Error: ${e.message}`, "err");
    }
  }

  queueBackground(gen) {
    for (const e of this.entries) {
      if (e.missing) continue;
      if (e.type === "file" && e.is_media && !e.media && !e.probeError && probesEnabled(this.location)) {
        enqueueProbe({ pane: this, gen, run: () => this.fetchProbe(e, gen) });
      } else if (e.type === "folder" && !e.folder && this.path) {
        enqueueProbe({ pane: this, gen, run: () => this.fetchFolder(e, gen) });
      }
    }
  }

  async fetchProbe(entry, gen) {
    try {
      const r = await api("GET", "/api/probe?" + qs({ location: this.location, path: entry.path }));
      entry.media = r.media;
    } catch (e) {
      entry.probeError = e.message;
    }
    if (gen === this.gen) this.updateRow(entry);
  }

  async fetchFolder(entry, gen) {
    try {
      entry.folder = await api("GET", "/api/folderstats?" + qs({ location: this.location, path: entry.path }));
    } catch (e) {
      entry.folderError = e.message;
    }
    if (gen === this.gen) this.updateRow(entry);
  }

  renderHead() {
    this.thead.replaceChildren(...COLUMNS.map((c) => {
      const cls = [c.num ? "num" : "", this.sort.key === c.key ? "sorted" : "",
        this.sort.key === c.key && this.sort.desc ? "desc" : ""].join(" ");
      return el("th", { class: cls, onclick: () => this.setSort(c.key) }, c.label);
    }));
  }

  setSort(key) {
    this.sort = { key, desc: this.sort.key === key ? !this.sort.desc : false };
    this.renderHead();
    this.render();
  }

  sorted() {
    const col = COLUMNS.find((c) => c.key === this.sort.key);
    const dir = this.sort.desc ? -1 : 1;
    return [...this.entries].sort((a, b) => {
      if (a.type !== b.type) return a.type === "folder" ? -1 : 1;
      const x = col.get(a), y = col.get(b);
      if (x < y) return -dir;
      if (x > y) return dir;
      return a.name.localeCompare(b.name);
    });
  }

  render() {
    this.rows = new Map();
    const rows = this.sorted().map((e) => {
      const tr = this.rowFor(e);
      this.rows.set(e.path, tr);
      return tr;
    });
    if (!rows.length) rows.push(el("tr", {}, el("td", { colspan: COLUMNS.length, class: "muted" }, "Empty")));
    this.tbody.replaceChildren(...rows);
  }

  updateRow(e) {
    const old = this.rows?.get(e.path);
    if (!old) return;
    const tr = this.rowFor(e);
    old.replaceWith(tr);
    this.rows.set(e.path, tr);
    if (selection?.entry === e) renderSelection();
  }

  rowFor(e) {
    const m = e.media;
    const isDir = e.type === "folder";
    const pendingMedia = e.is_media && !m && !e.probeError && probesEnabled(this.location);
    const cell = (text, cls = "") => el("td", { class: cls + (pendingMedia ? " pending" : "") }, text);
    const mediaCell = (val, cls = "") => cell(pendingMedia ? "…" : val, cls);
    let size;
    if (isDir) size = e.folder ? fmtSize(e.folder.size) : (e.folderError ? "error" : (this.path ? "…" : DASH));
    else size = fmtSize(e.size);
    const nameExtra = isDir && e.folder ? el("span", { class: "muted" }, ` (${e.folder.files} files)`) : null;
    const tr = el("tr", {
      class: this.selectedPath === e.path ? "selected" : "",
      title: e.probeError ? `ffprobe: ${e.probeError}` : (e.folderError || e.path),
      onclick: () => { this.selectedPath = e.path; this.markSelected(); setSelection({ pane: this, entry: e }); },
      ondblclick: () => { if (isDir && !e.missing) this.navigate(e.path); },
    },
      el("td", { class: "name" }, el("span", { class: "icon" }, isDir ? "📁" : (e.is_media ? "🎞" : "📄")), e.name, nameExtra,
        e.missing ? el("span", { class: "err" }, " (missing)") : null,
        e.probeError ? el("span", { class: "err" }, " ⚠") : null),
      el("td", { class: "num" }, size),
      mediaCell(v(m?.resolution)),
      mediaCell(v(m?.video_codec)),
      mediaCell(fmtRate(m?.video_bitrate), "num"),
      mediaCell(m ? v(m.main_audio_codec) + (m.main_audio_channels ? ` ${m.main_audio_channels}ch` : "") : DASH),
      mediaCell(fmtRate(m?.main_audio_bitrate), "num"),
      mediaCell(fmtDur(m?.duration), "num"),
      el("td", {}, fmtTime(e.mtime)));
    return tr;
  }

  markSelected() {
    for (const [p, tr] of this.rows) tr.classList.toggle("selected", p === this.selectedPath);
  }
}

function setActivePane(p) {
  for (const x of panes) x.root.classList.toggle("active", x === p);
}

function savePanes() {
  store.set("panes", panes.map((p) => ({ location: p.location, path: p.path })));
}

// ---------- selection panel ----------

let scanState = null; // {id, location, path, data, timer}
const selBody = document.getElementById("selection-body");

function setSelection(sel) {
  selection = sel;
  renderSelection();
}

function otherPane(p) {
  return panes.find((x) => x !== p) || p;
}

function refreshSendTargets() {
  // keep send-to defaults in sync with the other pane, unless the user edited them
  if (selection && !selection.dstEdited) renderSelection();
}

function renderSelection() {
  if (!selection) {
    selBody.className = "muted";
    selBody.replaceChildren("Click a file or folder to see details.");
    return;
  }
  const { pane, entry: e } = selection;
  const m = e.media;
  selBody.className = "";

  const rows = [
    ["Location", pane.location], ["Path", el("span", { class: "mono" }, e.path)], ["Type", e.type],
    ["Size", e.type === "folder" ? (e.folder ? `${fmtSize(e.folder.size)} (${e.folder.size.toLocaleString()} B), ${e.folder.files} files` : DASH)
      : `${fmtSize(e.size)} (${e.size?.toLocaleString() ?? DASH} B)`],
    ["Modified", fmtTime(e.mtime)],
  ];
  if (e.probeError) rows.push(["ffprobe", el("span", { class: "err" }, e.probeError)]);
  if (m) {
    rows.push(
      ["Container", v(m.container)],
      ["Duration", fmtDur(m.duration)],
      ["Video", `${v(m.video_codec)} ${m.video_profile ? "(" + m.video_profile + ")" : ""} ${v(m.resolution)}`],
      ["Video bitrate (metadata)", fmtRate(m.video_bitrate)],
      ["Main audio", `${v(m.main_audio_codec)} ${m.main_audio_channels ? m.main_audio_channels + "ch" : ""}`],
      ["Main audio bitrate (metadata)", fmtRate(m.main_audio_bitrate)],
      ["Tracks", `${m.audio_tracks} audio, ${m.subtitle_tracks} subtitle`],
      ["Overall bitrate (metadata)", fmtRate(m.format_bitrate)],
    );
    if (m.measured && m.scan) {
      const sc = m.scan;
      rows.push(
        ["Video (measured)", `${fmtSize(m.video_size)} · ${fmtRate(sc.main_video?.bitrate)}`],
        ["Main audio (measured)", `${fmtSize(m.main_audio_size)} · ${fmtRate(sc.main_audio?.bitrate)}`],
        ["All audio (measured)", `${fmtSize(m.total_audio_size)} · ${fmtRate(m.total_audio_bitrate)}`],
      );
    }
  }
  const details = el("dl", { class: "details" }, rows.flatMap(([k, val]) => [el("dt", {}, k), el("dd", {}, val)]));

  // send-to
  const target = otherPane(pane);
  if (!selection.dstEdited) {
    selection.dstLocation = target.location !== pane.location ? target.location
      : (LOCATIONS.find((l) => l.name !== pane.location)?.name ?? pane.location);
    selection.dstPath = target.location === selection.dstLocation ? target.path : "";
  }
  const dstSel = el("select", { onchange: () => { selection.dstEdited = true; selection.dstLocation = dstSel.value; } },
    LOCATIONS.filter((l) => l.name !== pane.location).map((l) => el("option", { value: l.name }, l.name)));
  dstSel.value = selection.dstLocation;
  const dstPath = el("input", { class: "dst-path", placeholder: "destination folder", value: selection.dstPath || "",
    spellcheck: "false", oninput: () => { selection.dstEdited = true; selection.dstPath = dstPath.value; } });
  const sendBtn = el("button", { class: "primary", onclick: () => startTransfer(pane.location, e.path, dstSel.value, dstPath.value.trim()) }, "Transfer");

  const canScan = e.type === "file" && !e.missing && probesEnabled(pane.location);
  const scanBtn = el("button", { disabled: !canScan || (scanState && scanState.running),
    title: probesEnabled(pane.location) ? null : "Local ffprobe is unavailable (see the message at the top)",
    onclick: () => startScan(pane.location, e.path) }, "Detailed scan");

  const actions = el("div", { class: "sel-actions" }, scanBtn, el("span", { class: "muted" }, "Send to"), dstSel, dstPath, sendBtn);
  const msg = el("div", { id: "sel-msg" });

  const left = el("div", {}, details, actions, msg);
  const right = el("div", {}, m ? streamTable(m.streams) : null, scanView(pane.location, e.path, m));
  selBody.replaceChildren(el("div", { class: "sel-columns" }, left, right));
}

function streamTable(streams) {
  if (!streams?.length) return null;
  return el("div", {},
    el("h2", {}, "Streams (metadata)"),
    el("table", { class: "grid" },
      el("thead", {}, el("tr", {}, ["#", "Type", "Codec", "Lang", "Title", "Ch", "Resolution", "Bitrate", "Flags"].map((h) => el("th", {}, h)))),
      el("tbody", {}, streams.map((s) => el("tr", {},
        el("td", {}, s.index), el("td", {}, v(s.type)), el("td", {}, v(s.codec) + (s.profile ? ` (${s.profile})` : "")),
        el("td", {}, v(s.language)), el("td", {}, v(s.title)), el("td", {}, v(s.channels)),
        el("td", {}, v(s.resolution)), el("td", { class: "num" }, fmtRate(s.bitrate)),
        el("td", {}, [s.default && "default", s.forced && "forced", s.attached_pic && "cover"].filter(Boolean).join(", ")))))));
}

function setMsg(text, cls = "") {
  const m = document.getElementById("sel-msg");
  if (m) { m.className = cls; m.textContent = text; }
}

// ---------- detailed scan ----------

function scanView(location, path, media) {
  let d;
  if (scanState && scanState.location === location && scanState.path === path) d = scanState.data;
  else if (media?.scan) d = { state: "done", result: media.scan, elapsed: null }; // measured earlier (cached)
  else return null;
  const box = el("div", { class: "scan-box" }, el("h2", {}, "Detailed scan (measured from packets)"));
  if (!d) return box;
  if (d.state === "running") {
    const pct = d.progress !== null ? (d.progress * 100) : null;
    box.append(el("div", { class: "sel-actions" },
      progressBar(pct, pct === null ? "scanning…" : `${pct.toFixed(1)}%`),
      el("span", { class: "muted" }, `${fmtDur(d.position)} / ${fmtDur(d.duration)} · ${d.elapsed}s`),
      el("button", { onclick: cancelScan }, "Cancel")));
    return box;
  }
  if (d.state === "failed") { box.append(el("div", { class: "err" }, `Scan failed: ${d.error}`)); return box; }
  if (d.state === "cancelled") { box.append(el("div", { class: "muted" }, "Scan cancelled.")); return box; }
  const r = d.result;
  const line = (label, x) => el("tr", {}, el("td", {}, label), el("td", {}, x ? v(x.codec ?? `${x.tracks} tracks`) : DASH),
    el("td", { class: "num" }, fmtSize(x?.size)), el("td", { class: "num" }, x?.size?.toLocaleString() ?? DASH),
    el("td", { class: "num" }, fmtRate(x?.bitrate)));
  box.append(
    el("div", { class: "muted" }, `${d.elapsed !== null ? `Completed in ${d.elapsed}s. ` : "Cached result. "}Bitrate = size × 8 / the stream's own duration (container: ${fmtDur(r.duration)}).`),
    el("table", { class: "grid" },
      el("thead", {}, el("tr", {}, ["", "Codec", "Size", "Bytes", "Bitrate"].map((h, i) => el("th", { class: i >= 2 ? "num" : "" }, h)))),
      el("tbody", {},
        line("Main video", r.main_video),
        line("Main audio", r.main_audio),
        line("Total audio", r.total_audio),
        el("tr", {}, el("td", {}, "Subtitles"), el("td", {}, `${r.subtitles.count} tracks`),
          el("td", { class: "num" }, fmtSize(r.subtitles.size)), el("td", { class: "num" }, r.subtitles.size.toLocaleString()), el("td", {})),
        el("tr", {}, el("td", {}, "Other streams"), el("td", {}, r.other_streams.length ? r.other_streams.map((s) => `#${s.index} ${s.type}/${s.codec}`).join(", ") : "none"),
          el("td", {}), el("td", {}), el("td", {})))),
    el("table", { class: "grid" },
      el("thead", {}, el("tr", {}, ["#", "Type", "Codec", "Packets", "Size", "Duration", "Measured bitrate"].map((h, i) => el("th", { class: i >= 3 ? "num" : "" }, h)))),
      el("tbody", {}, r.streams.map((s) => el("tr", {},
        el("td", {}, s.index), el("td", {}, v(s.type)), el("td", {}, v(s.codec)),
        el("td", { class: "num" }, s.packets?.toLocaleString() ?? DASH), el("td", { class: "num" }, fmtSize(s.size)),
        el("td", { class: "num", title: durTitle(s) }, fmtDurPrecise(s.duration),
          s.duration_source === "container" ? el("span", { class: "muted" }, " (container)") : null),
        el("td", { class: "num" }, fmtRate(s.measured_bitrate)))))),
    r.streams.some((s) => s.duration_source === "container")
      ? el("div", { class: "muted" }, "(container): the stream's own duration was unavailable or under 1 s, so the container duration was used.")
      : null);
  return box;
}

function progressBar(pct, label) {
  return el("div", { class: "bar" }, el("span", { style: `width:${Math.max(0, Math.min(100, pct ?? 0))}%` }), el("em", {}, label));
}

async function startScan(location, path) {
  try {
    const r = await api("POST", "/api/scan", { location, path });
    scanState = { id: r.scan_id, location, path, data: r, running: true };
    renderSelection();
    pollScan();
  } catch (e) {
    setMsg(`Scan failed to start: ${e.message}`, "err");
  }
}

async function pollScan() {
  const s = scanState;
  if (!s || !s.running) return;
  try {
    s.data = await api("GET", `/api/scan/${s.id}`);
  } catch (e) {
    s.data = { state: "failed", error: e.message };
  }
  if (scanState !== s) return;
  s.running = s.data.state === "running";
  if (s.data.state === "done" && s.data.result?.media) {
    // propagate measured values to any pane row showing this file
    const { media, ...scan } = s.data.result;
    for (const p of panes) {
      const ent = p.entries.find((x) => x.path === s.path && p.location === s.location);
      if (ent) { ent.media = { ...media, scan }; p.updateRow(ent); }
    }
  }
  renderSelection();
  if (s.running) setTimeout(pollScan, 500);
}

async function cancelScan() {
  if (!scanState) return;
  try { scanState.data = await api("DELETE", `/api/scan/${scanState.id}`); } catch { /* polled anyway */ }
}

// ---------- transfers ----------

const conflictDialog = document.getElementById("conflict-dialog");

function askConflict(info) {
  return new Promise((resolve) => {
    document.getElementById("conflict-text").textContent =
      `"${info.dst_path}" already exists (${info.dst_type}). What should happen?`;
    document.getElementById("conflict-rename").textContent = `Rename to "${info.suggested_name}"`;
    conflictDialog.returnValue = "cancel";
    conflictDialog.onclose = () => resolve(conflictDialog.returnValue || "cancel");
    conflictDialog.showModal();
  });
}

async function startTransfer(srcLoc, srcPath, dstLoc, dstDir, onConflict = null) {
  if (!dstDir) { setMsg("Choose a destination folder (navigate there in the other pane, or type a path).", "err"); return; }
  setMsg("Checking destination…", "muted");
  try {
    const r = await api("POST", "/api/transfers", { src_location: srcLoc, src_path: srcPath, dst_location: dstLoc, dst_dir: dstDir, on_conflict: onConflict });
    setMsg(r.skipped ? "Skipped (destination exists)." : `Transfer queued → ${r.dst_location}:${r.dst_path}`, r.skipped ? "muted" : "ok");
    pollTransfers();
  } catch (e) {
    if (e.status === 409 && e.data?.conflict) {
      const choice = await askConflict(e.data);
      if (choice === "cancel") { setMsg("Transfer cancelled.", "muted"); return; }
      return startTransfer(srcLoc, srcPath, dstLoc, dstDir, choice);
    }
    setMsg(`Transfer refused: ${e.message}`, "err");
  }
}

const transferRows = document.getElementById("transfer-rows");
const seenDone = new Set();
let transferTimer = null;

async function pollTransfers() {
  clearTimeout(transferTimer);
  try {
    const list = await api("GET", "/api/transfers");
    renderTransfers(list);
    for (const t of list) {
      if (t.state === "done" && !seenDone.has(t.id)) {
        seenDone.add(t.id);
        for (const p of panes) if (p.location === t.dst_location && p.path === t.dst_dir) p.load();
      }
    }
  } catch { /* server restarting; keep polling */ }
  transferTimer = setTimeout(pollTransfers, 1000);
}

function renderTransfers(list) {
  if (!list.length) {
    transferRows.replaceChildren(el("tr", {}, el("td", { colspan: 8, class: "muted" }, "No transfers yet.")));
    return;
  }
  transferRows.replaceChildren(...list.map((t) => {
    const active = t.state === "queued" || t.state === "running";
    const phase = t.kind === "relay" && t.phase ? ` (${t.phase})` : "";
    const fileInfo = t.is_dir ? ` · ${t.files_done}/${t.files_total} files` : "";
    return el("tr", {},
      el("td", { title: t.current_file || t.name }, (t.is_dir ? "📁 " : "") + t.name),
      el("td", { class: "route", title: `${t.src_location}:${t.src_path} → ${t.dst_location}:${t.dst_path}` },
        `${t.src_location} → ${t.kind === "relay" ? "Local → " : ""}${t.dst_location}:${t.dst_dir}`),
      el("td", {}, progressBar(t.percent, `${t.percent.toFixed(1)}%${phase}`)),
      el("td", { class: "num" }, `${fmtSize(t.done)} / ${fmtSize(t.total)}${fileInfo}`),
      el("td", { class: "num" }, active ? fmtSpeed(t.speed) : (t.avg_speed ? `avg ${fmtSpeed(t.avg_speed)}` : DASH)),
      el("td", { class: "num" }, active ? fmtDur(t.eta) : DASH),
      el("td", { class: t.state === "failed" ? "err" : (t.state === "done" ? "ok" : "") }, t.state + (t.error ? `: ${t.error}` : "")),
      el("td", {}, active ? el("button", { onclick: () => api("DELETE", `/api/transfers/${t.id}`).then(pollTransfers) }, "Cancel") : null));
  }));
}

// ---------- local ffprobe status ----------

function renderBanner() {
  const b = document.getElementById("banner");
  if (!LOCAL_FFPROBE || LOCAL_FFPROBE.ok) { b.hidden = true; b.replaceChildren(); return; }
  b.hidden = false;
  b.replaceChildren(
    el("span", {}, el("strong", {}, "Local ffprobe unavailable — media info and detailed scans for Local files are disabled. "),
      LOCAL_FFPROBE.error),
    el("button", { onclick: recheckFfprobe }, "Re-check"));
}

async function recheckFfprobe() {
  const was = LOCAL_FFPROBE?.ok;
  try { LOCAL_FFPROBE = (await api("POST", "/api/status/ffprobe")).local_ffprobe; } catch { return; }
  renderBanner();
  if (LOCAL_FFPROBE.ok && !was) for (const p of panes) if (p.location === "Local") p.load();
  if (selection) renderSelection();
}

// ---------- stale .part files ----------

const staleDialog = document.getElementById("stale-dialog");
const staleBody = document.getElementById("stale-body");
let staleItems = [];
const staleKey = (it) => `${it.location}|${it.path}|${it.mtime}`;

async function checkStale(fromBoot = false) {
  const btn = document.getElementById("check-stale");
  btn.disabled = true;
  btn.textContent = "Checking…";
  let r;
  try {
    r = await api("GET", "/api/stale-parts");
  } catch (e) {
    if (!fromBoot) alert(`Stale file check failed: ${e.message}`);
    return;
  } finally {
    btn.disabled = false;
    btn.textContent = "Check for stale files";
  }
  staleItems = r.items;
  if (fromBoot) {
    // on startup only pop up for files the user hasn't already chosen to ignore
    const ignored = new Set(store.get("ignoredStale", []));
    if (!staleItems.some((it) => !ignored.has(staleKey(it)))) return;
  }
  renderStale(r.skipped);
  if (!staleDialog.open) staleDialog.showModal();
}

function renderStale(skipped = [], results = null) {
  const notes = skipped.map((s) => el("div", { class: "err" }, `Skipped ${s.location}: ${s.error}`));
  if (results) {
    for (const r of results.filter((x) => !x.ok)) notes.push(el("div", { class: "err" }, `Not deleted ${r.location}:${r.path}: ${r.error}`));
    const n = results.filter((x) => x.ok).length;
    if (n) notes.push(el("div", { class: "ok" }, `Deleted ${n} file${n === 1 ? "" : "s"}.`));
  }
  const hasItems = staleItems.length > 0;
  document.getElementById("stale-delete-selected").disabled = !hasItems;
  document.getElementById("stale-delete-all").disabled = !hasItems;
  if (!hasItems) {
    staleBody.replaceChildren(...notes, el("p", {}, "No stale .part files found."));
    return;
  }
  const all = el("input", { type: "checkbox", title: "Select all",
    onchange: () => staleBody.querySelectorAll("tbody input").forEach((c) => { c.checked = all.checked; }) });
  staleBody.replaceChildren(...notes, el("table", { class: "grid" },
    el("thead", {}, el("tr", {}, el("th", {}, all), el("th", {}, "Location"), el("th", {}, "Path"),
      el("th", { class: "num" }, "Size"), el("th", {}, "Modified"))),
    el("tbody", {}, staleItems.map((it, i) => el("tr", {},
      el("td", {}, el("input", { type: "checkbox", "data-i": i })),
      el("td", {}, it.location), el("td", { class: "path" }, it.path),
      el("td", { class: "num" }, fmtSize(it.size)), el("td", {}, fmtTime(it.mtime)))))));
}

async function deleteStale(items) {
  if (!items.length) return;
  const total = items.reduce((a, it) => a + (it.size || 0), 0);
  if (!confirm(`Delete ${items.length} .part file${items.length === 1 ? "" : "s"} (${fmtSize(total)})? This cannot be undone.`)) return;
  let r;
  try {
    r = await api("DELETE", "/api/stale-parts", items.map((it) => ({ location: it.location, path: it.path })));
  } catch (e) {
    alert(`Delete failed: ${e.message}`);
    return;
  }
  const deleted = new Set(r.results.filter((x) => x.ok).map((x) => `${x.location}|${x.path}`));
  staleItems = staleItems.filter((it) => !deleted.has(`${it.location}|${it.path}`));
  renderStale([], r.results);
  for (const p of panes) p.load();
}

document.getElementById("check-stale").onclick = () => checkStale(false);
document.getElementById("stale-delete-selected").onclick = () =>
  deleteStale([...staleBody.querySelectorAll("tbody input:checked")].map((c) => staleItems[Number(c.dataset.i)]));
document.getElementById("stale-delete-all").onclick = () => deleteStale(staleItems);
document.getElementById("stale-ignore").onclick = () => {
  const ignored = new Set(store.get("ignoredStale", []));
  for (const it of staleItems) ignored.add(staleKey(it));
  store.set("ignoredStale", [...ignored].slice(-500));
  staleDialog.close();
};

// ---------- boot ----------

async function boot() {
  try {
    LOCATIONS = await api("GET", "/api/locations");
    LOCAL_FFPROBE = (await api("GET", "/api/status")).local_ffprobe;
    renderBanner();
  } catch (e) {
    document.getElementById("panes").append(el("div", { class: "err" }, `Cannot load locations: ${e.message}`));
    return;
  }
  const names = new Set(LOCATIONS.map((l) => l.name));
  let saved = store.get("panes", null);
  if (!Array.isArray(saved) || saved.length < 1 || !saved.every((p) => names.has(p.location))) {
    saved = [{ location: LOCATIONS[0].name, path: "" }, { location: (LOCATIONS[1] || LOCATIONS[0]).name, path: "" }];
  }
  for (const p of saved) new Pane(p.location, p.path || "");
  setActivePane(panes[0]);
  document.getElementById("add-pane").onclick = () => {
    const p = new Pane(LOCATIONS[0].name, "");
    setActivePane(p);
  };
  pollTransfers();
  checkStale(true);
}

boot();
