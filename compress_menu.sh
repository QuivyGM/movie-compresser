#!/usr/bin/env bash
set -euo pipefail

BASE="$HOME/compress"

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
