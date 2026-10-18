# vkshim

A small `libvulkan.1.dylib` that passes every Vulkan call through to MoltenVK and ignores
debug object names and labels. SDL3 games such as ASTRIDER Demo name their Vulkan objects,
and that crashes under the Wine 11.13 runtime.

Recipes with `"vkshim": true` get it on `mage install` and `mage run`. Mage keeps the original
file as `libvulkan.1.dylib.stock` and only swaps files while that runtime is not running.

`prebuilt/libvulkan.1.dylib` is built for x86_64 because Wine loads it, so no compiler is
needed. To rebuild it, run `build.sh` and copy `libvulkan.1.dylib` into `prebuilt/`.
