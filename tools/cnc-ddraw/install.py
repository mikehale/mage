#!/usr/bin/env python3
import hashlib
import os
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

VERSION = "7.1.0.0"
URL = f"https://github.com/FunkyFr3sh/cnc-ddraw/releases/download/v{VERSION}/cnc-ddraw.zip"
SHA256 = "0b13ab89a64c9918189b1dadd449ef6ed3cb3b7b19cabd96d8adbd95505bb908"
STAMP = ".mage-cnc-ddraw"


def install_files(game):
    with tempfile.TemporaryDirectory() as tmp:
        archive = Path(tmp) / "cnc-ddraw.zip"
        subprocess.run(["curl", "-fsSL", "-o", str(archive), URL], check=True)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        if digest != SHA256:
            sys.exit(f"cnc-ddraw: checksum mismatch ({digest})")
        with zipfile.ZipFile(archive) as z:
            for name in z.namelist():
                if name.endswith("/"):
                    continue
                if name == "ddraw.dll" or name.startswith("Shaders/") \
                        or (name == "ddraw.ini" and not (game / name).exists()):
                    dst = game / name
                    dst.parent.mkdir(parents=True, exist_ok=True)
                    dst.write_bytes(z.read(name))
    (game / STAMP).write_text(VERSION + "\n")
    print(f"cnc-ddraw: installed {VERSION} into {game}")


def apply_settings(ini, settings):
    text = ini.read_bytes().decode("latin-1")
    nl = "\r\n" if "\r\n" in text else "\n"
    lines = text.split(nl)
    start = next(i for i, l in enumerate(lines) if l.strip().lower() == "[ddraw]")
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("[")), len(lines))
    pending = dict(settings)
    for i in range(start + 1, end):
        key = lines[i].split("=", 1)[0].strip()
        if key in pending:
            lines[i] = f"{key}={pending.pop(key)}"
    lines[start + 1:start + 1] = [f"{k}={v}" for k, v in pending.items()]
    out = nl.join(lines)
    if out != text:
        ini.write_bytes(out.encode("latin-1"))
        print(f"cnc-ddraw: updated {ini}")


def set_override(exe):
    wine = os.environ["WINE"]
    key = rf"HKCU\Software\Wine\AppDefaults\{exe}\DllOverrides"
    q = subprocess.run([wine, "reg", "query", key, "/v", "ddraw"],
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    if "native,builtin" in q.stdout:
        return
    subprocess.run([wine, "reg", "add", key, "/v", "ddraw", "/t", "REG_SZ",
                    "/d", "native,builtin", "/f"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    print(f"cnc-ddraw: ddraw=native,builtin for {exe}")


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: install.py <game dir> <exe> [key=value ...]")
    game = Path(sys.argv[1])
    exe = sys.argv[2]
    settings = dict(a.split("=", 1) for a in sys.argv[3:])
    if not (game / exe).is_file():
        print(f"cnc-ddraw: {game / exe} not installed yet, skipping")
        return
    stamp = game / STAMP
    if not stamp.is_file() or stamp.read_text().strip() != VERSION \
            or not (game / "ddraw.dll").is_file():
        install_files(game)
    if settings:
        apply_settings(game / "ddraw.ini", settings)
    set_override(exe)


if __name__ == "__main__":
    main()
