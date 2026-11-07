#!/usr/bin/env bash
set -euo pipefail

BASE="$HOME/compress"

# work/ may be a symlink to another disk; it is never recreated here
if [[ ! -d "$BASE/work" ]]; then
    if [[ -L "$BASE/work" ]]; then
        echo "ERROR: $BASE/work is a broken symlink (-> $(readlink -- "$BASE/work")). Is its disk mounted?"
    else
        echo "ERROR: $BASE/work not found."
    fi
    exit 1
fi

echo
echo "Compression:"
echo "1) Movie"
echo "2) Series"

while true; do
    read -rp "Select [1-2]: " choice

    case "$choice" in
        1)
            exec "$BASE/work/movie_compress.sh"
            ;;
        2)
            exec "$BASE/work/series_compress.sh"
            ;;
        *)
            echo "Invalid selection."
            ;;
    esac
done
