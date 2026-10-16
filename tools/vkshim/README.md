# vkshim

A tiny `libvulkan.1.dylib` that forwards every call to MoltenVK but turns
`vkSetDebugUtilsObjectNameEXT` / `...ObjectTagEXT` / debug labels into no-ops.

Why: SDL3 GPU games (e.g. ASTRIDER Demo, Steam app 4950960) name every Vulkan object.
Under wiage 11.13 this crashes right after swapchain creation:
`err:vulkan:vkSetDebugUtilsObjectNameEXT Exception 0xc0000005 in Unix call`.

## Build / install
    tools/vkshim/build.sh            # universal dylib; fetches Vulkan-Headers on first run
    # copy as libvulkan.1.dylib into the runtime's MoltenVK dir (vulkan_library_path) and
    # into lib/wine/x86_64-unix, with libMoltenVK.dylib beside it. The shim locates MoltenVK itself.

## Tested: ASTRIDER Demo
M3 Max, macOS 26.6.2, release preview-2026-08-02 (wiage 11.13 + MageVK). With the shim and
`recipes/astrider-demo.example.json` the game reaches the menu and plays.
Steam needs the steamwebhelper wrapper (black window otherwise). Install the demo through the
Steam UI; `steam-install` fails for an account that doesn't own it yet.
