# xinput-fix

Patched Wine `winexinput.sys` and `xinput*.dll` that make an Xbox One S controller over
Bluetooth (`045e:02fd`) work as an XInput gamepad. Over Bluetooth the pad uses a different
layout than over USB, and stock Wine maps its sticks, triggers and buttons wrong.

Recipes with `"xinput_fix": true` get it on `mage install` and `mage run`. Mage keeps the
originals as `<name>.stock` and only swaps files while that runtime is not running. To undo,
move the `.stock` files back. The recipes also set winebus `Enable SDL`=0 and
`DisableInput`=1, and `SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS=1` so games keep reading the pad
after the window is minimized and restored.

- `winexinput-xbox-bt.patch`, `xinput-xbox-bt.patch`: the source changes.
- `x86_64-windows/`: the built files.

## Build

Against the Wine 11.13 source, with Homebrew's mingw-w64 and bison:

    export PATH=/opt/homebrew/opt/bison/bin:$PATH
    tar xf wine-11.13.tar.xz
    patch -d wine-11.13 -p1 < winexinput-xbox-bt.patch
    patch -d wine-11.13 -p1 < xinput-xbox-bt.patch
    mkdir build && cd build
    ../wine-11.13/configure --enable-win64 --host=x86_64-apple-darwin 'CC=clang -arch x86_64' --without-x
    for d in winexinput.sys xinput1_1 xinput1_2 xinput1_3 xinput1_4 xinput9_1_0 xinputuap; do
      make dlls/$d/all
    done

Then run `x86_64-w64-mingw32-strip --strip-all` on each `build/dlls/<name>/x86_64-windows/`
file and copy it into `x86_64-windows/`.
