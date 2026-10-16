#!/bin/bash
# Builds libvulkan.1.dylib shim (universal) that forwards to MoltenVK and no-ops VK_EXT_debug_utils names/tags/labels.
set -euo pipefail
cd "$(dirname "$0")"
HDR="${VK_HEADERS:-./Vulkan-Headers}"
[ -d "$HDR/include/vulkan" ] || git clone --depth 1 https://github.com/KhronosGroup/Vulkan-Headers.git "$HDR"
clang -arch x86_64 -arch arm64 -O2 -shared -fvisibility=hidden -I"$HDR/include" \
  -install_name @rpath/libvulkan.1.dylib -o libvulkan.1.dylib shim.c
echo "built $(pwd)/libvulkan.1.dylib"
