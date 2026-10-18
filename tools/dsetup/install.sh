#!/bin/sh
set -e
[ $# -eq 1 ] || { echo "usage: install.sh <game dir>" >&2; exit 2; }
src="drive_c/Program Files (x86)/Steam/steamapps/common/Steamworks Shared/_CommonRedist/DirectX/Jun2010"
[ -d "$1" ] || { echo "dsetup: $1 not installed yet, skipping"; exit 0; }
for f in DSETUP.dll dsetup32.dll; do
    [ -f "$src/$f" ] || { echo "dsetup: missing $src/$f" >&2; exit 1; }
    if ! cmp -s "$src/$f" "$1/$f"; then
        cp -f "$src/$f" "$1/$f"
        echo "dsetup: copied $f into $1"
    fi
done
