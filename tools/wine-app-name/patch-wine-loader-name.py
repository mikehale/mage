#!/usr/bin/env python3
"""Create a per-app copy of the wine loader with a patched embedded Info.plist.

Wine's loader binary embeds an Info.plist (__TEXT,__info_plist) with
CFBundleName "Wine". Launch Services reads it at checkin and that becomes the
Dock tile / menu bar name — setProcessName cannot override it. ntdll also
re-execs the loader as "wine" by fixed name, so renaming the binary alone is
not enough: mage-wine's ntdll honors MAGE_APP_NAME and execs a same-named
sibling of the default loader instead (see dlls/ntdll/unix/loader.c).

This script creates that sibling: a copy of the loader with CFBundleName /
CFBundleExecutable / CFBundleIdentifier rewritten to the app name. The Mach-O
section size field is updated to fit the new plist (the section has file slack
after it).

Usage: patch-wine-loader-name.py <wine-prefix-install> <AppName> [bundle-id]
  <wine-prefix-install> = install root containing lib/wine/x86_64-unix/wine
Output: lib/wine/x86_64-unix/<AppName> next to the original loader.
Refreshes the copy when missing or older than the original loader.
"""
import os
import plistlib
import re
import struct
import subprocess
import sys

CODESIGN = '/usr/bin/codesign'
LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'


def patch(src, dst, appname, bundleid, display=None):
    # appname = loader file name (CFBundleExecutable must match it);
    # display = CFBundleName shown in Dock/menu bar (defaults to appname)
    display = display or appname
    data = bytearray(open(src, 'rb').read())
    assert struct.unpack_from('<I', data, 0)[0] == 0xfeedfacf, "not a 64-bit Mach-O"
    ncmds = struct.unpack_from('<I', data, 16)[0]
    off = 32
    sect = None
    offsets = []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from('<II', data, off)
        if cmd == 0x19:  # LC_SEGMENT_64
            nsects = struct.unpack_from('<I', data, off + 64)[0]
            so = off + 72
            for _ in range(nsects):
                offsets.append(struct.unpack_from('<I', data, so + 48)[0])
                if data[so:so + 16].split(b'\0')[0] == b'__info_plist':
                    sect = so
                so += 80
        off += cmdsize
    assert sect is not None, "no __info_plist section"
    size = struct.unpack_from('<Q', data, sect + 40)[0]
    foff = struct.unpack_from('<I', data, sect + 48)[0]
    xml = bytes(data[foff:foff + size])
    xml = xml.replace(b'<string>Wine</string>', f'<string>{display}</string>'.encode())
    xml = xml.replace(b'<string>wine</string>', f'<string>{appname}</string>'.encode(), 1)
    xml = xml.replace(b'org.winehq.wine', bundleid.encode())
    xml = re.sub(rb'>\s+<', b'><', xml).strip() + b'\n'
    limit = min([o for o in offsets if o > foff] + [len(data)])
    assert foff + len(xml) <= limit, "plist overflows __info_plist"
    pad = max(size - len(xml), 0)
    data[foff:foff + len(xml) + pad] = xml + bytes(pad)
    struct.pack_into('<Q', data, sect + 40, len(xml))
    tmp = dst + '.tmp'
    with open(tmp, 'wb') as f:
        f.write(bytes(data))
    os.chmod(tmp, 0o755)
    sign(tmp, bundleid)
    os.replace(tmp, dst)


def sign(path, ident):
    subprocess.run([CODESIGN, '-f', '-s', '-', '-i', ident, path], capture_output=True)


def embedded_name(path):
    m = re.search(rb'<key>CFBundleName</key>\s*<string>([^<]*)</string>', open(path, 'rb').read())
    return m.group(1).decode() if m else None


def prebuilt_tramp():
    tramp = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'prebuilt', 'mage-tramp')
    return tramp if os.access(tramp, os.X_OK) else None


def link_ntdll(unix, d):
    target = os.path.realpath(os.path.join(unix, 'ntdll.so'))
    link = os.path.join(d, 'ntdll.so')
    if os.path.realpath(link) != target:
        if os.path.lexists(link):
            os.remove(link)
        os.symlink(target, link)


def bundle(install, appname, bundleid, display, app):
    tramp = prebuilt_tramp()
    if not tramp:
        return False
    unix = os.path.join(install, 'lib', 'wine', 'x86_64-unix')
    loader = os.path.join(unix, 'wine')
    info = os.path.join(app, 'Contents', 'Info.plist')
    if os.path.exists(info):
        with open(info, 'rb') as f:
            d = plistlib.load(f)
        bundleid, display = d.get('CFBundleIdentifier', bundleid), d.get('CFBundleName', display)
    else:
        os.makedirs(os.path.dirname(info), exist_ok=True)
        with open(info, 'wb') as f:
            plistlib.dump({'CFBundleExecutable': appname, 'CFBundleIdentifier': bundleid,
                           'CFBundleName': display, 'CFBundlePackageType': 'APPL',
                           'LSUIElement': True}, f)
    inner = os.path.join(app, 'Contents', 'MacOS', appname)
    plain = os.path.join(unix, 'mage-plain', appname)
    dst = os.path.join(unix, appname)
    cfg = dst + '.bundle-loader'
    newest = max(os.path.getmtime(p) for p in (loader, info, tramp))
    if all(os.path.exists(p) and os.path.getmtime(p) >= newest for p in (inner, plain, dst, cfg)) \
            and open(cfg).read().strip() == inner:
        print(f"up to date: {dst} -> {inner}")
        return True
    for p in (inner, plain):
        os.makedirs(os.path.dirname(p), exist_ok=True)
        patch(loader, p, appname, bundleid, display)
        link_ntdll(unix, os.path.dirname(p))
    with open(cfg, 'w') as f:
        f.write(inner + '\n')
    with open(tramp, 'rb') as f, open(dst + '.tmp', 'wb') as g:
        g.write(f.read())
    os.chmod(dst + '.tmp', 0o755)
    sign(dst + '.tmp', bundleid)
    os.replace(dst + '.tmp', dst)
    subprocess.run([LSREGISTER, '-f', app])
    print(f"created: {dst} -> {inner} (bundle id {bundleid})")
    return True


def main():
    args = sys.argv[1:]
    app = None
    if '--bundle' in args:
        i = args.index('--bundle')
        app = args[i + 1]
        del args[i:i + 2]
    install, appname = args[0], args[1]
    bundleid = args[2] if len(args) > 2 else \
        'app.mage.' + ''.join(c.lower() if c.isalnum() else '-' for c in appname).strip('-')
    # optional 4th arg: display name when it differs from the loader file
    # name (e.g. loader "Steamwebhelper_real" shows as "Steam" — ntdll picks
    # the loader by exe-derived name, Launch Services shows the plist name)
    display = args[3] if len(args) > 3 else appname
    if app and bundle(install, appname, bundleid, display, app):
        return
    loader = os.path.join(install, 'lib', 'wine', 'x86_64-unix', 'wine')
    dst = os.path.join(install, 'lib', 'wine', 'x86_64-unix', appname)
    if os.path.exists(dst) and os.path.getmtime(dst) >= os.path.getmtime(loader) \
            and embedded_name(dst) == display:
        print(f"up to date: {dst}")
        return
    patch(loader, dst, appname, bundleid, display)
    print(f"created: {dst} (bundle id {bundleid})")


if __name__ == '__main__':
    main()
