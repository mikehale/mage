#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
HDR="${VK_HEADERS:-./Vulkan-Headers}"
[ -d "$HDR/include/vulkan" ] || git clone --depth 1 https://github.com/KhronosGroup/Vulkan-Headers.git "$HDR"
clang -arch x86_64 -O2 -shared -fvisibility=hidden -I"$HDR/include" \
  -install_name @rpath/libvulkan.1.dylib -o libvulkan.1.dylib shim.c
codesign -f -s - libvulkan.1.dylib
echo "built $(pwd)/libvulkan.1.dylib"
