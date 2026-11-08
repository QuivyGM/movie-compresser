#!/usr/bin/env bash
# Compression provenance of the files under ~/compress/out (PROVENANCE.md).
#
#   provenance.sh scan    [PATH...] [--json]     what is known about each file
#                                                (read-only; default: out/)
#   provenance.sh tag     PATH... [--dry-run]    give files without provenance an
#                                                ID tag + manifest record (tags
#                                                only, never re-encodes)
#   provenance.sh relink  [PATH...] [--dry-run]  record moved / renamed files and
#                                                recover lost records from the
#                                                embedded tags (manifest only)
#   provenance.sh compare [PATH...] [--json]     recorded compressor versions vs
#                                                this checkout (read-only)
#   provenance.sh show    ID|FILE                one manifest record (JSON)
#   provenance.sh ingest                         merge events jobs left in the
#                                                spool (python3 was missing)
#   provenance.sh rebuild [--dry-run]            rebuild the manifest from its
#                                                journal
#
# Manifest: ~/compress/work/logs/provenance/manifest.json (PROVENANCE_DIR
# overrides). Nothing here encodes or remuxes media; only `tag` writes to
# a media file, and only its global tags (mkvpropedit).
set -u

BASE="${COMPRESS_BASE:-$HOME/compress}"
WORK="$BASE/work"
LIB="$WORK/lib"

if [[ ! -f "$LIB/provenance.py" ]]; then
    echo "provenance.sh: $LIB/provenance.py not found (COMPRESS_BASE=$BASE)" >&2
    exit 1
fi
# shellcheck source=work/lib/provenance.sh
source "$LIB/provenance.sh"

if ! py=$(prov_python); then
    echo "provenance.sh: python 3.6 or newer is required (python3 not found)" >&2
    exit 1
fi
command -v ffprobe >/dev/null 2>&1 ||
    echo "provenance.sh: ffprobe not found: media properties and tags cannot be read" >&2

export PROV_BASH="${BASH:-bash}"
exec "$py" "$LIB/provenance.py" --work "$WORK" --out "$BASE/out" \
    ${PROVENANCE_DIR:+--manifest-dir "$PROVENANCE_DIR"} "$@"
