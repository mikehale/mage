#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p prebuilt
clang -arch arm64 -O2 -o prebuilt/mage-tramp mage-tramp.c
codesign -f -s - prebuilt/mage-tramp
echo "built $(pwd)/prebuilt/mage-tramp"
