#!/usr/bin/env python3
import os
import re
import subprocess
import sys


def current(wine, key, name, kind):
    r = subprocess.run([wine, "reg", "query", key, "/v", name],
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    m = re.search(rf"^\s*{re.escape(name)}\s+{kind}\s+(.*?)\s*$", r.stdout, re.M | re.I)
    if not m:
        return None
    return str(int(m.group(1), 0)) if kind == "REG_DWORD" else m.group(1)


def main():
    args = sys.argv[1:]
    if not args or len(args) % 4:
        sys.exit("usage: set.py <key> <name> <REG_SZ|REG_DWORD> <value> [...]")
    wine = os.environ["WINE"]
    for key, name, kind, value in zip(*[iter(args)] * 4):
        want = str(int(value, 0)) if kind == "REG_DWORD" else value
        if current(wine, key, name, kind) == want:
            continue
        subprocess.run([wine, "reg", "add", key, "/v", name, "/t", kind, "/d", value, "/f"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        print(f"wine-reg: {key}\\{name}={value}")


if __name__ == "__main__":
    main()
