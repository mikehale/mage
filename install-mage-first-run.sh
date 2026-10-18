#!/bin/bash
# install-mage-first-run.sh: set up Mage on a new Mac, no Command Line Tools needed.
#
# Installs Mage.app into /Applications (an existing copy is kept as a backup) and creates the
# Mage folder in ~/Library/Application Support/Mage with the Mage source, the runtime, a bundled
# Python, the controller fix and vkshim, and a shared Steam bottle with the ASTRIDER Demo and
# Total Annihilation recipes. It never changes an existing Mage folder.
# Quit Mage, Steam and games first.
#
# Usage: ./install-mage-first-run.sh [--dry-run] [--skip-steam] [--launch-steam]
#   --dry-run       show what would happen; change nothing
#   --skip-steam    create the bottle without the Steam client (install it later)
#   --launch-steam  open Steam at the end to sign in and install a game
#
# MAGE_SRC_REPO and MAGE_SRC_REF choose the Mage source. APP_DEST, MAGE_DATA, MAGE_CACHE,
# MAGE_APP_SRC, MAGE_INSTALLER_SCRATCH=1, MAGE_DEFAULTS_DOMAIN and SKIP_DEFAULTS=1 install
# somewhere else.
set -euo pipefail

TS=$(date +%Y%m%d-%H%M%S)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY=0 SKIP_STEAM=0 LAUNCH_STEAM=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|-n) DRY=1 ;;
    --skip-steam) SKIP_STEAM=1 ;;
    --launch-steam) LAUNCH_STEAM=1 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

REAL_ROOT="$HOME/Library/Application Support/Mage"
APP_DEST="${APP_DEST:-/Applications}"
MAGE_DATA="${MAGE_DATA:-$REAL_ROOT}"
MAGE_CACHE="${MAGE_CACHE:-$HOME/Library/Caches/mage-installer}"
DEFAULTS_DOMAIN="${MAGE_DEFAULTS_DOMAIN:-app.mage.runner}"
SKIP_DEFAULTS="${SKIP_DEFAULTS:-0}"
SCRATCH="${MAGE_INSTALLER_SCRATCH:-0}"
UPSTREAM="dttdrv/mage"
APP_REPO="mikehale/mage"
SRC_REPO="${MAGE_SRC_REPO:-$APP_REPO}"
LAST_RESORT_RUNTIME_TAG="preview-2026-08-02"
LAST_RESORT_WIAGE_SHA="d0cea7ff492dd3801dfa26a2a7d5ed1331e60f65929318d17301a3ce9cbba56c"
LAST_RESORT_MAGEVK_SHA="849d24b809f60e73631e6fa9d92bfbeea04178ceb04ad828bfd457a02a9452e5"
LAST_RESORT_SRC_SHA="3d482d1781dbbedb6b086dd56f0371fe084a06e2"

ROOT="$MAGE_DATA"
STATE="$ROOT/.mage-installer"
PREFIX="$ROOT/prefixes/steam"
WINE="$ROOT/dist/wiage/bin/wine"
WINESERVER="$ROOT/dist/wiage/bin/wineserver"
STEAM_EXE_REL="drive_c/Program Files (x86)/Steam/steam.exe"
PY_SHA="5e656e09fc73c7ae10e4df66e6aa253f1f5980509b3be8a242e883d67a5fdf26"
PY_URL="https://github.com/astral-sh/python-build-standalone/releases/download/20261013/cpython-3.11.17%2B20261013-aarch64-apple-darwin-install_only_stripped.tar.gz"
PY_TRIM="lib/libpython3.11.dylib lib/libtcl9.0.dylib lib/libtcl9tk9.0.dylib lib/tcl9 lib/tcl9.0 lib/tk9.0 lib/itcl4.3.8 lib/thread3.0.6 lib/pkgconfig include share
  lib/python3.11/idlelib lib/python3.11/tkinter lib/python3.11/turtledemo lib/python3.11/ensurepip lib/python3.11/lib2to3
  lib/python3.11/pydoc_data lib/python3.11/config-3.11-darwin lib/python3.11/site-packages bin/2to3 bin/2to3-3.11 bin/idle3
  bin/idle3.11 bin/pip bin/pip3 bin/pip3.11 bin/pydoc3 bin/pydoc3.11 bin/python3-config bin/python3.11-config"
PY="$ROOT/dist/python/bin/python3"
INSTALL_RECIPES="astrider-demo total-annihilation"
XINPUT_FILES="winexinput.sys xinput1_1.dll xinput1_2.dll xinput1_3.dll xinput1_4.dll xinput9_1_0.dll xinputuap.dll"

say()  { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    warning: %s\n' "$*" >&2; }
die()  { printf '\nerror: %s\n' "$*" >&2; exit 1; }
run()  { if [ "$DRY" = 1 ]; then printf '    [dry-run]'; printf ' %q' "$@"; echo; else "$@"; fi; }
sha()  { shasum -a 256 "$1" | awk '{print $1}'; }
jget() { plutil -extract "$2" raw -o - "$1" 2>/dev/null; }
jlen() { local n=0; while plutil -extract "${2:+$2.}$n" json -o /dev/null "$1" 2>/dev/null; do n=$((n + 1)); done; echo "$n"; }
releases_newest_first() {
  local i n; n=$(jlen "$1")
  for ((i = 0; i < n; i++)); do
    [ "$(jget "$1" "$i.draft")" = true ] && continue
    printf '%s %s\n' "$(jget "$1" "$i.published_at" || true)" "$i"
  done | sort -r | awk '{print $NF}'
}
asset_index() {
  local j n; n=$(jlen "$1" "$2.assets")
  for ((j = 0; j < n; j++)); do
    [[ "$(jget "$1" "$2.assets.$j.name")" =~ ^$3$ ]] && { echo "$j"; return 0; }
  done
  return 1
}
asset_digest() { local d; d=$(jget "$1" "$2.assets.$3.digest" || true); [[ "$d" == sha256:* ]] && echo "${d#sha256:}" || true; }

MANIFEST_LINES=""
record() { MANIFEST_LINES="$MANIFEST_LINES$*
"; info "$*"; }

fetch() {
  local url="$1" dest="$2" want="${3:-}"
  if [ -f "$dest" ] && { [ -z "$want" ] || [ "$(sha "$dest")" = "$want" ]; }; then
    info "cached: $(basename "$dest")"; return 0
  fi
  if [ "$DRY" = 1 ]; then info "[dry-run] download $url"; return 0; fi
  mkdir -p "$(dirname "$dest")"
  info "downloading $url"
  local progress=-sS; [ -t 2 ] && progress=--progress-bar
  curl -fL --retry 3 "$progress" -o "$dest.part" "$url" || { /bin/rm -f "$dest.part"; return 1; }
  if [ -n "$want" ] && [ "$(sha "$dest.part")" != "$want" ]; then
    /bin/rm -f "$dest.part"; warn "sha256 mismatch for $url"; return 1
  fi
  /bin/mv -f "$dest.part" "$dest"
}

install_file() {
  local src="$1" dst="$2" stock="$2.stock" tmp
  tmp="$(dirname "$2")/.$(basename "$2").mage-tmp"
  if { [ -e "$dst" ] || [ -L "$dst" ]; } && [ ! -e "$stock" ] && [ ! -L "$stock" ]; then
    if [ -L "$dst" ]; then ln -s "$(readlink "$dst")" "$stock"; else /bin/cp -p "$dst" "$stock"; fi
  fi
  /bin/rm -f "$tmp"
  /bin/cp -p "$src" "$tmp"
  case "$dst" in *.dylib) chmod 755 "$tmp" ;; esac
  /bin/mv -f "$tmp" "$dst"
  info "installed $(basename "$dst")"
}


busy_processes() {
  ps axww -o pid=,command= | awk -v me="$$" '$1 != me' \
    | grep -i -E '(^|/)(wineserver|wine|wine64|wine-preloader|wine64-preloader)( |$)|\.exe( |"|$)|/Mage\.app/Contents/MacOS/Mage|/Launchers/[^/]+\.app/|steamwebhelper' \
    | grep -v -E 'grep -i -E|install-mage' || true
}

say "Preflight"
[ "$(uname -s)" = Darwin ] || die "macOS only"
[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] || die "Mage needs a Mac with Apple silicon"
for t in curl shasum tar ditto codesign xattr defaults file plutil; do command -v "$t" >/dev/null || die "missing $t"; done
if [ "$SCRATCH" = 1 ]; then
  [ "$APP_DEST" != /Applications ] && [ "$ROOT" != "$REAL_ROOT" ] \
    || die "MAGE_INSTALLER_SCRATCH=1 needs a scratch APP_DEST and MAGE_DATA"
  if [ "$DEFAULTS_DOMAIN" = app.mage.runner ] && [ "$SKIP_DEFAULTS" != 1 ]; then
    warn "MAGE_INSTALLER_SCRATCH=1: the real app.mage.runner defaults will not be written"; SKIP_DEFAULTS=1
  fi
fi
[ "$DRY" = 1 ] && info "dry run: nothing will be changed"
info "app destination: $APP_DEST/Mage.app"
info "Mage folder:     $ROOT"
info "download cache:  $MAGE_CACHE"
BUSY=$(busy_processes)
if [ -n "$BUSY" ]; then
  printf '%s\n' "$BUSY" | sed 's/^/    running: /' >&2
  if [ "$DRY" = 1 ]; then warn "a real run would stop here: quit Mage, Steam and games first"
  elif [ "$SCRATCH" = 1 ]; then warn "MAGE_INSTALLER_SCRATCH=1 with scratch folders: continuing"
  else die "Mage, Steam, a game, or Wine is running. Quit them (don't force-kill Steam), then re-run."; fi
else
  info "no Mage, Steam or Wine processes running"
fi
if [ -e "$ROOT" ] && [ -n "$(ls -A "$ROOT" 2>/dev/null)" ]; then
  if [ -f "$STATE/incomplete" ]; then
    die "an earlier run of this installer did not finish in $ROOT. Delete that folder and re-run."
  fi
  die "$ROOT already exists, so Mage is already set up on this Mac. This first-run installer
       never changes an existing Mage folder. To start over, move it away (e.g. to the Trash) and re-run."
fi
mkdir -p "$MAGE_CACHE"

say "1/7 Resolve latest releases (app: $APP_REPO; runtime: $UPSTREAM; source: $SRC_REPO)"
RESOLVED=github RUNTIME_SHA_SRC="GitHub digest" APP_SHA_SRC="GitHub digest"
RUNTIME_TAG="" WIAGE_SHA="" MAGEVK_SHA="" APP_TAG="" APP_ASSET="" APP_SHA="" APP_PRERELEASE=0 SRC_BRANCH="" SRC_SHA=""
REL_JSON="$MAGE_CACHE/releases.json"
if curl -fsSL --retry 2 -o "$REL_JSON.part" "https://api.github.com/repos/$UPSTREAM/releases?per_page=50"; then
  /bin/mv -f "$REL_JSON.part" "$REL_JSON"
  for i in $(releases_newest_first "$REL_JSON"); do
    w=$(asset_index "$REL_JSON" "$i" 'wiage-runtime\.tar\.gz') && m=$(asset_index "$REL_JSON" "$i" 'magevk-lib\.tar\.gz') || continue
    RUNTIME_TAG=$(jget "$REL_JSON" "$i.tag_name")
    WIAGE_SHA=$(asset_digest "$REL_JSON" "$i" "$w")
    MAGEVK_SHA=$(asset_digest "$REL_JSON" "$i" "$m")
    break
  done
else
  /bin/rm -f "$REL_JSON.part"
fi
APP_JSON="$MAGE_CACHE/app-releases.json"
if curl -fsSL --retry 2 -o "$APP_JSON.part" "https://api.github.com/repos/$APP_REPO/releases?per_page=50"; then
  /bin/mv -f "$APP_JSON.part" "$APP_JSON"
else
  /bin/rm -f "$APP_JSON.part" "$APP_JSON"
fi
if command -v git >/dev/null && LSR=$(git ls-remote --symref "https://github.com/$UPSTREAM" HEAD 2>/dev/null); then
  SRC_BRANCH=$(printf '%s\n' "$LSR" | awk '$1 == "ref:" {sub("refs/heads/", "", $2); print $2; exit}')
  SRC_SHA=$(printf '%s\n' "$LSR" | awk '$2 == "HEAD" && $1 != "ref:" {print $1; exit}')
fi
if [ -z "$SRC_SHA" ]; then
  J="$MAGE_CACHE/api-$TS.json"
  curl -fsSL -o "$J" "https://api.github.com/repos/$UPSTREAM" 2>/dev/null && SRC_BRANCH=$(jget "$J" default_branch) || true
  [ -z "$SRC_BRANCH" ] || { curl -fsSL -o "$J" "https://api.github.com/repos/$UPSTREAM/commits/$SRC_BRANCH" 2>/dev/null && SRC_SHA=$(jget "$J" sha) || true; }
  /bin/rm -f "$J"
fi
if [ -z "$RUNTIME_TAG" ]; then
  RESOLVED=last-resort
  warn "could not list $UPSTREAM releases; using the pinned runtime $LAST_RESORT_RUNTIME_TAG"
  RUNTIME_SHA_SRC="last-resort pin" RUNTIME_TAG="$LAST_RESORT_RUNTIME_TAG" WIAGE_SHA="$LAST_RESORT_WIAGE_SHA" MAGEVK_SHA="$LAST_RESORT_MAGEVK_SHA"
fi
if [ -z "$SRC_SHA" ]; then
  RESOLVED=last-resort
  warn "could not resolve $UPSTREAM HEAD; using the pinned commit ${LAST_RESORT_SRC_SHA:0:7}"
  SRC_BRANCH="main" SRC_SHA="$LAST_RESORT_SRC_SHA"
fi
record "runtime release: $RUNTIME_TAG"
[ -n "$WIAGE_SHA" ] && [ -n "$MAGEVK_SHA" ] || warn "GitHub published no sha256 for some runtime assets; they will be recorded, not verified"

fetch_asset() {
  local dest="$MAGE_CACHE/${1%%/*}/$2/$3"
  fetch "https://github.com/$1/releases/download/$2/$3" "$dest" "$4" || die "could not download $3 ($1 $2)"
  [ "$DRY" = 1 ] && return 0
  if [ -n "$4" ]; then record "sha256 $3 ($1 $2): $(sha "$dest") (matches $5)"
  else record "sha256 $3 ($1 $2): $(sha "$dest") (unverified: no published digest)"; fi
}
app_digest() {
  [ -f "$APP_JSON" ] || return 0
  local i j n
  n=$(jlen "$APP_JSON")
  for ((i = 0; i < n; i++)); do
    j=$(asset_index "$APP_JSON" "$i" "$(printf '%s' "$1" | sed 's/[.[\*^$+?(){}|]/\\&/g')") || continue
    asset_digest "$APP_JSON" "$i" "$j"; return 0
  done
}

say "2/7 Mage.app -> $APP_DEST"
APP="$APP_DEST/Mage.app"
LOCAL_ZIP=""
for z in "$SCRIPT_DIR"/Mage-*.zip; do [ -f "$z" ] && LOCAL_ZIP="$z"; done
LOCAL_APP="${MAGE_APP_SRC:-}"
[ -n "$LOCAL_APP" ] || [ -n "$LOCAL_ZIP" ] || [ ! -x "$SCRIPT_DIR/Mage.app/Contents/MacOS/Mage" ] || LOCAL_APP="$SCRIPT_DIR/Mage.app"
STAGE=""
unzip_app() {
  local dir="$MAGE_CACHE/unzipped-$TS"
  /bin/rm -rf "$dir" && mkdir -p "$dir"
  ditto -x -k "$1" "$dir"
  STAGE="$dir/Mage.app"
  [ -x "$STAGE/Contents/MacOS/Mage" ] || die "$(basename "$1") has no Mage.app"
}
if [ -n "$LOCAL_APP" ]; then
  [ -x "$LOCAL_APP/Contents/MacOS/Mage" ] || die "$LOCAL_APP is not a Mage.app"
  [ -d "$APP" ] && [ "$(cd "$LOCAL_APP" && pwd -P)" = "$(cd "$APP" && pwd -P)" ] \
    && die "$LOCAL_APP is the installed app; run this script from the folder you downloaded Mage into"
  STAGE="$LOCAL_APP"
  record "app: local copy $LOCAL_APP (no published sha256 for an unzipped app)"
elif [ -n "$LOCAL_ZIP" ]; then
  WANT=$(app_digest "$(basename "$LOCAL_ZIP")")
  if [ -n "$WANT" ]; then
    [ "$(sha "$LOCAL_ZIP")" = "$WANT" ] || die "$(basename "$LOCAL_ZIP") does not match the sha256 GitHub publishes for it; download it again"
    record "app: local $(basename "$LOCAL_ZIP"), sha256 $WANT (matches GitHub digest)"
  else
    record "app: local $(basename "$LOCAL_ZIP"), sha256 $(sha "$LOCAL_ZIP") (unverified: not found in $APP_REPO releases)"
  fi
  [ "$DRY" = 1 ] || unzip_app "$LOCAL_ZIP"
else
  if [ -f "$APP_JSON" ]; then
    for i in $(releases_newest_first "$APP_JSON"); do
      j=$(asset_index "$APP_JSON" "$i" 'Mage-.+\.zip') || continue
      APP_TAG=$(jget "$APP_JSON" "$i.tag_name")
      APP_ASSET=$(jget "$APP_JSON" "$i.assets.$j.name")
      APP_SHA=$(asset_digest "$APP_JSON" "$i" "$j")
      [ "$(jget "$APP_JSON" "$i.prerelease")" = true ] && APP_PRERELEASE=1
      break
    done
  fi
  if [ -z "$APP_TAG" ]; then
    die "could not find a Mage release on $APP_REPO. Download Mage-*.zip next to this script and re-run."
  fi
  record "app release:     $APP_REPO $APP_TAG ($APP_ASSET)$( [ "$APP_PRERELEASE" = 1 ] && echo ', pre-release')"
  [ -n "$APP_SHA" ] || warn "GitHub published no sha256 for $APP_ASSET; it will be recorded, not verified"
  fetch_asset "$APP_REPO" "$APP_TAG" "$APP_ASSET" "$APP_SHA" "$APP_SHA_SRC"
  [ "$DRY" = 1 ] || unzip_app "$MAGE_CACHE/${APP_REPO%%/*}/$APP_TAG/$APP_ASSET"
fi
if [ -e "$APP" ]; then
  run /bin/mv "$APP" "$APP_DEST/Mage.app.backup-$TS"
  info "previous app kept as $APP_DEST/Mage.app.backup-$TS"
fi
run mkdir -p "$APP_DEST"
run ditto "${STAGE:-Mage.app}" "$APP"
[ "$DRY" = 1 ] || [ -z "$STAGE" ] || [ "$STAGE" = "${LOCAL_APP:-}" ] || /bin/rm -rf "$(dirname "$STAGE")"
if [ -n "${MAGE_SRC_REF:-}" ]; then
  SRC_BRANCH="" SRC_SHA="$MAGE_SRC_REF"
elif [ "$SRC_REPO" = "$APP_REPO" ]; then
  SRC_TAG="$APP_TAG"
  if [ -z "$SRC_TAG" ] && [ -n "$LOCAL_ZIP" ]; then z=$(basename "$LOCAL_ZIP" .zip); [ "$z" = "${z#Mage-}" ] || SRC_TAG="v${z#Mage-}"; fi
  if [ -n "$SRC_TAG" ]; then
    SRC_BRANCH="" SRC_SHA="$SRC_TAG"
  else
    warn "no release tag for this app; installing $UPSTREAM source instead (set MAGE_SRC_REF to pin one)"
    SRC_REPO="$UPSTREAM"
  fi
fi
record "source:          $SRC_REPO ${SRC_BRANCH:+$SRC_BRANCH }@ $SRC_SHA"

say "3/7 Enable Mage.app (quarantine, signature)"
run xattr -dr com.apple.quarantine "$APP"
if [ "$DRY" = 1 ]; then
  info "[dry-run] codesign --verify --deep --strict; re-sign ad hoc only if that fails"
else
  if codesign --verify --deep --strict "$APP" 2>/dev/null; then
    info "signature ok"
  else
    info "signature invalid after copy; re-signing ad hoc"
    codesign --force --deep -s - "$APP"
    codesign --verify --deep --strict "$APP" || die "Mage.app signature check failed"
  fi
  if xattr -r "$APP" 2>/dev/null | grep -q com.apple.quarantine; then die "quarantine flag still set on $APP"; fi
  record "app installed: $APP ($(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo '?')), quarantine cleared, signature verified"
fi

say "4/7 Mage folder: source $SRC_SHA and runtime $RUNTIME_TAG at $ROOT"
SRC_TGZ="$MAGE_CACHE/src/${SRC_REPO%%/*}-mage-$SRC_SHA.tar.gz"
WIAGE_TGZ="$MAGE_CACHE/${UPSTREAM%%/*}/$RUNTIME_TAG/wiage-runtime.tar.gz"
MAGEVK_TGZ="$MAGE_CACHE/${UPSTREAM%%/*}/$RUNTIME_TAG/magevk-lib.tar.gz"
fetch "https://codeload.github.com/$SRC_REPO/tar.gz/$SRC_SHA" "$SRC_TGZ" || die "could not download Mage source"
fetch_asset "$UPSTREAM" "$RUNTIME_TAG" wiage-runtime.tar.gz "$WIAGE_SHA" "$RUNTIME_SHA_SRC"
fetch_asset "$UPSTREAM" "$RUNTIME_TAG" magevk-lib.tar.gz "$MAGEVK_SHA" "$RUNTIME_SHA_SRC"
if [ "$DRY" = 1 ]; then
  info "[dry-run] extract source, wiage and MageVK into $ROOT"
else
  mkdir -p "$STATE" && : > "$STATE/incomplete"
  trap '[ -f "$STATE/incomplete" ] && printf "\nThe Mage folder %s is incomplete. Delete it, then re-run.\n" "$ROOT" >&2' EXIT
  record "sha256 source tarball $SRC_REPO@$SRC_SHA: $(sha "$SRC_TGZ")"
  tar xzf "$SRC_TGZ" -C "$ROOT" --strip-components 1
  chmod +x "$ROOT/bin/mage"
  echo "$SRC_SHA" > "$STATE/source-ref"
  mkdir -p "$ROOT/prefixes" "$ROOT/recipes" "$ROOT/runtimes" "$ROOT/dist/magevk/lib"
  tar xzf "$WIAGE_TGZ" -C "$ROOT/dist"
  tar xzf "$MAGEVK_TGZ" -C "$ROOT/dist/magevk/lib"
  [ -x "$WINE" ] || die "runtime has no $WINE"
  echo "$RUNTIME_TAG" > "$ROOT/dist/.mage-release"
  RT_JSON="$ROOT/runtimes/mage-wine-11.13-rt.json"
  if [ -f "$ROOT/runtimes/mage-wine-11.13-rt.example.json" ]; then
    /bin/cp -p "$ROOT/runtimes/mage-wine-11.13-rt.example.json" "$RT_JSON"
  else
    cat > "$RT_JSON" <<'JSON'
{
  "id": "mage-wine-11.13-rt",
  "root": "dist/wiage",
  "wine": "bin/wine",
  "wineserver": "bin/wineserver",
  "vulkan_library_path": "dist/magevk/lib",
  "notes": "Wiage runtime + MageVK libraries (written by install-mage-first-run.sh)."
}
JSON
  fi
  info "source, runtime and runtime manifest in place"
fi

say "4b/7 Bundled Python (python-build-standalone 3.11.17) -> $ROOT/dist/python"
PY_TGZ="$MAGE_CACHE/python/$(basename "${PY_URL//%2B/+}")"
fetch "$PY_URL" "$PY_TGZ" "$PY_SHA" || die "could not download the bundled Python"
if [ "$DRY" = 1 ]; then
  info "[dry-run] extract to dist/python, trim tk/idle/pip/headers, check json/ssl/tarfile/zipfile import"
else
  /bin/rm -rf "$ROOT/dist/python"
  tar xzf "$PY_TGZ" -C "$ROOT/dist"
  (cd "$ROOT/dist/python" && /bin/rm -rf $PY_TRIM lib/python3.11/lib-dynload/_tkinter.*)
  "$PY" -c 'import json, ssl, tarfile, zipfile, urllib.request, plistlib' || die "bundled Python does not run"
  record "python: $(basename "$PY_TGZ") sha256 $PY_SHA, $(du -sh "$ROOT/dist/python" | awk '{print $1}') after trim"
fi

say "5/7 Controller fix and vkshim"
WINLIB="$ROOT/dist/wiage/lib/wine/x86_64-windows"
[ "$DRY" = 1 ] || [ -d "$WINLIB" ] || die "runtime has no $WINLIB"
for n in $XINPUT_FILES; do
  src="$ROOT/tools/xinput-fix/x86_64-windows/$n"
  if [ "$DRY" = 1 ]; then info "[dry-run] $WINLIB/$n <- $src"; continue; fi
  [ -f "$src" ] || die "the Mage source has no $src"
  install_file "$src" "$WINLIB/$n"
  cmp -s "$src" "$WINLIB/$n" || die "$n check failed after install"
done
[ "$DRY" = 1 ] || info "controller fix installed and verified"

SHIM="$ROOT/tools/vkshim/prebuilt/libvulkan.1.dylib" SHIM_SHA=""
if [ "$DRY" != 1 ]; then [ -f "$SHIM" ] || die "the Mage source has no $SHIM"; SHIM_SHA=$(sha "$SHIM"); fi
member_sha() {
  local tmp="$MAGE_CACHE/member-$TS" rc=0
  /bin/rm -rf "$tmp" && mkdir -p "$tmp"
  if tar xzf "$1" -C "$tmp" "$2" 2>/dev/null; then sha "$tmp/$2"; else rc=1; fi
  /bin/rm -rf "$tmp"
  return $rc
}
mvk_ok() {
  local f="$1" s
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  s=$(sha "$f")
  [ "$s" != "$SHIM_SHA" ] && [ "$(stat -f %z "$f")" -gt 1000000 ] && file -b "$f" | grep -q Mach-O || return 1
  [ -z "$2" ] || [ "$s" = "$2" ]
}
if [ "$DRY" = 1 ]; then
  info "[dry-run] vkshim -> dist/magevk/lib and dist/wiage/lib/wine/x86_64-unix (links replaced, not written through)"
  info "[dry-run] verify both libMoltenVK.dylib against the runtime tarballs"
else
  for d in "$ROOT/dist/magevk/lib" "$ROOT/dist/wiage/lib/wine/x86_64-unix"; do install_file "$SHIM" "$d/libvulkan.1.dylib"; done
  MVK_WANT_WIAGE=$(member_sha "$WIAGE_TGZ" wiage/lib/libMoltenVK.dylib || true)
  MVK_WANT_MAGEVK=$(member_sha "$MAGEVK_TGZ" libMoltenVK.dylib || true)
  mvk_ok "$ROOT/dist/wiage/lib/libMoltenVK.dylib" "$MVK_WANT_WIAGE" || die "MoltenVK check failed: wiage/lib/libMoltenVK.dylib"
  mvk_ok "$ROOT/dist/magevk/lib/libMoltenVK.dylib" "$MVK_WANT_MAGEVK" || die "MoltenVK check failed: magevk/lib/libMoltenVK.dylib"
  for f in "$ROOT/dist/magevk/lib/libvulkan.1.dylib" "$ROOT/dist/wiage/lib/wine/x86_64-unix/libvulkan.1.dylib"; do
    [ ! -L "$f" ] && [ "$(sha "$f")" = "$SHIM_SHA" ] || die "vkshim check failed: $f"
  done
  info "MoltenVK intact (matches the $RUNTIME_TAG tarballs); vkshim in both Vulkan load paths"
fi

say "5b/7 Clear quarantine and ad hoc sign unsigned Mach-O files in $ROOT"
if [ "$DRY" = 1 ]; then
  info "[dry-run] xattr -dr com.apple.quarantine $ROOT; codesign -f -s - every Mach-O whose signature does not verify"
else
  xattr -dr com.apple.quarantine "$ROOT" 2>/dev/null || true
  n=0
  while IFS= read -r -d '' f; do
    file -b "$f" | grep -q Mach-O || continue
    codesign -v "$f" >/dev/null 2>&1 && continue
    codesign -f -s - "$f" >/dev/null 2>&1 || die "could not sign $f"
    n=$((n + 1))
  done < <(find "$ROOT/dist" "$ROOT/tools" -type f -print0)
  if xattr -r "$ROOT" 2>/dev/null | grep -q com.apple.quarantine; then die "quarantine flag still set in $ROOT"; fi
  record "quarantine cleared in $ROOT, $n Mach-O files signed ad hoc"
fi

say "6/7 First bottle: shared Steam bottle $PREFIX (ASTRIDER Demo)"
merge_recipe() {
  local want; want=$(cat)
  "$PY" - "$ROOT/recipes/$1.json" "$want" <<'PY'
import json, os, sys
path = sys.argv[1]
want = json.loads(sys.argv[2])
have = json.load(open(path)) if os.path.isfile(path) else {}
missing = [k for k in want if k not in have]
if missing or not have:
    have.update({k: want[k] for k in missing})
    with open(path, "w") as f:
        json.dump(have, f, indent=2, sort_keys=True)
        f.write("\n")
print(f"    recipe {os.path.basename(path)}: " + (f"added {', '.join(missing)}" if missing else "up to date"))
PY
}
recipe_astrider_demo() {
  cat <<'JSON'
{
  "env": {
    "ROSETTA_ADVERTISE_AVX": "1",
    "WINEDEBUG": "-all",
    "WINEDLLOVERRIDES": "mscoree=d;mshtml=d",
    "WINEESYNC": "0",
    "WINEMSYNC": "1"
  },
  "icon": "astrider-demo.icns",
  "id": "astrider-demo",
  "launch": [
    {
      "args": [
        "-silent",
        "-nobootstrapupdate",
        "-skipinitialbootstrap",
        "-noverifyfiles",
        "-cef-disable-gpu",
        "-cef-disable-gpu-compositing"
      ],
      "background": true,
      "program": "C:\\Program Files (x86)\\Steam\\steam.exe",
      "then_wait": 20
    },
    {
      "app_exes": [
        "astrider.exe"
      ],
      "args": [
        "-applaunch",
        "4950960"
      ],
      "background": true,
      "program": "C:\\Program Files (x86)\\Steam\\steam.exe"
    }
  ],
  "runtime": "mage-wine-11.13-rt",
  "setup": [
    [
      "tools/wine-reg/set.py",
      "HKLM\\System\\CurrentControlSet\\Services\\winebus",
      "Enable SDL",
      "REG_DWORD",
      "0",
      "HKLM\\System\\CurrentControlSet\\Services\\winebus",
      "DisableInput",
      "REG_DWORD",
      "1",
      "HKCU\\Environment",
      "SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS",
      "REG_SZ",
      "1"
    ]
  ],
  "steam_appid": "4950960",
  "title": "ASTRIDER Demo",
  "vkshim": true,
  "xinput_fix": true
}
JSON
}
recipe_total_annihilation() {
  cat <<'JSON'
{
  "env": {
    "ROSETTA_ADVERTISE_AVX": "1",
    "WINEDEBUG": "-all",
    "WINEDLLOVERRIDES": "mscoree=d;mshtml=d",
    "WINEESYNC": "0",
    "WINEMSYNC": "1"
  },
  "id": "total-annihilation",
  "launch": [
    {
      "args": [
        "-silent",
        "-nobootstrapupdate",
        "-skipinitialbootstrap",
        "-noverifyfiles",
        "-cef-disable-gpu",
        "-cef-disable-gpu-compositing"
      ],
      "background": true,
      "program": "C:\\Program Files (x86)\\Steam\\steam.exe",
      "then_wait": 20
    },
    {
      "app_exes": [
        "TotalA.exe"
      ],
      "args": [
        "-applaunch",
        "298030"
      ],
      "background": true,
      "program": "C:\\Program Files (x86)\\Steam\\steam.exe"
    }
  ],
  "runtime": "mage-wine-11.13-rt",
  "setup": [
    [
      "tools/wine-reg/set.py",
      "HKLM\\System\\CurrentControlSet\\Services\\winebus",
      "Enable SDL",
      "REG_DWORD",
      "0",
      "HKLM\\System\\CurrentControlSet\\Services\\winebus",
      "DisableInput",
      "REG_DWORD",
      "1",
      "HKCU\\Environment",
      "SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS",
      "REG_SZ",
      "1"
    ],
    [
      "tools/cnc-ddraw/install.py",
      "drive_c/Program Files (x86)/Steam/steamapps/common/Total Annihilation",
      "TotalA.exe",
      "fullscreen=true",
      "windowed=true",
      "maintas=true",
      "renderer=opengl"
    ],
    [
      "tools/dsetup/install.sh",
      "drive_c/Program Files (x86)/Steam/steamapps/common/Total Annihilation"
    ]
  ],
  "steam_appid": "298030",
  "title": "Total Annihilation",
  "xinput_fix": true
}
JSON
}
if [ "$DRY" = 1 ]; then info "[dry-run] merge missing keys into recipes: $INSTALL_RECIPES"
else
  for r in $INSTALL_RECIPES; do "recipe_${r//-/_}" | merge_recipe "$r"; done
fi
export WINEPREFIX="$PREFIX" WINEDEBUG=-all WINEDLLOVERRIDES="mscoree=d;mshtml=d"
wait_server() {
  local t="$1" pid
  "$WINESERVER" -w & pid=$!
  while [ "$t" -gt 0 ] && kill -0 "$pid" 2>/dev/null; do sleep 1; t=$((t - 1)); done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; return 1; fi
  wait "$pid" 2>/dev/null || true
}
STEAM="$PREFIX/$STEAM_EXE_REL"
CEF="$PREFIX/drive_c/Program Files (x86)/Steam/bin/cef/cef.win64/steamwebhelper.exe"
if [ "$DRY" = 1 ]; then
  info "[dry-run] bin/mage install astrider-demo --name steam (wineboot)"
  info "[dry-run] registry: winebus Enable SDL=0, DisableInput=1; HKCU\\Environment SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS=1"
  [ "$SKIP_STEAM" = 1 ] || info "[dry-run] install Steam (SteamSetup.exe /S), first-run client update, steamwebhelper wrapper"
  info "[dry-run] write $PREFIX/.mage-bottle.json (bottle astrider-demo, path under $ROOT)"
  info "[dry-run] register the other recipes in prefixes/imported.json: ${INSTALL_RECIPES#astrider-demo }"
else
  info "creating bottle (wineboot)"
  (cd "$ROOT" && "$PY" bin/mage install astrider-demo --name steam) >"$STATE/wineboot-$TS.log" 2>&1 \
    || die "bin/mage install failed (see $STATE/wineboot-$TS.log)"
  for kv in "Enable SDL=0" "DisableInput=1"; do
    "$WINE" reg add 'HKLM\System\CurrentControlSet\Services\winebus' /v "${kv%=*}" /t REG_DWORD /d "${kv#*=}" /f >/dev/null 2>&1 \
      || die "could not set winebus ${kv%=*}"
  done
  "$WINE" reg add 'HKCU\Environment' /v SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS /t REG_SZ /d 1 /f >/dev/null 2>&1 \
    || die "could not set SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS"
  wait_server 120 || die "this bottle's wineserver did not exit"
  info "registry: winebus Enable SDL=0, DisableInput=1; HKCU\\Environment SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS=1"

  if [ "$SKIP_STEAM" = 1 ]; then
    info "Steam install skipped (--skip-steam). Mage lists Steam games once $STEAM_EXE_REL exists in the bottle."
  else
    fetch https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe "$MAGE_CACHE/SteamSetup.exe" || die "could not download SteamSetup.exe"
    info "installing Steam client (silent)"
    "$WINE" "$MAGE_CACHE/SteamSetup.exe" /S
    wait_server 300 || die "Steam installer did not finish"
    [ -f "$STEAM" ] || die "Steam installer finished but $STEAM_EXE_REL is missing"
    info "first Steam run: downloading the client (a few minutes)"
    "$WINE" 'C:\Program Files (x86)\Steam\steam.exe' -silent >"$STATE/steam-firstrun-$TS.log" 2>&1 &
    for _ in $(seq 600); do [ -f "$CEF" ] && break; sleep 1; done
    [ -f "$CEF" ] || die "Steam client update did not finish (see $STATE/steam-firstrun-$TS.log)"
    sleep 30
    "$WINE" 'C:\Program Files (x86)\Steam\steam.exe' -shutdown >/dev/null 2>&1 || true
    if ! wait_server 120; then
      warn "Steam did not exit; stopping this new bottle's wineserver"; "$WINESERVER" -k || true; wait_server 60 || true
    fi
    (cd "$ROOT" && "$PY" bin/mage steam-wrapper "$PREFIX")
  fi

  "$PY" - "$PREFIX" <<'PY'
import json, os, sys, time
prefix = sys.argv[1]
marker = os.path.join(prefix, ".mage-bottle.json")
m = json.load(open(marker)) if os.path.isfile(marker) else {}
json.dump({"name": "astrider-demo", "recipe": "astrider-demo", "prefix": prefix,
           "created": m.get("created") or time.strftime("%Y-%m-%dT%H:%M:%S")}, open(marker, "w"), indent=2)
print(f"    bottle astrider-demo -> {prefix}")
PY
  for r in $INSTALL_RECIPES; do
    [ "$r" = astrider-demo ] && continue
    (cd "$ROOT" && "$PY" bin/mage install "$r" --name "$r" --import-prefix "$PREFIX") >>"$STATE/wineboot-$TS.log" 2>&1 \
      || die "could not register $r (see $STATE/wineboot-$TS.log)"
    info "bottle $r -> $PREFIX (prefixes/imported.json)"
  done
fi

say "7/7 Point Mage at $ROOT (MageRootOverride)"
if [ "$SKIP_DEFAULTS" = 1 ]; then
  info "skipped (SKIP_DEFAULTS=1): would run defaults write $DEFAULTS_DOMAIN MageRootOverride -string \"$ROOT\""
else
  [ "$DRY" = 1 ] || [ -x "$ROOT/bin/mage" ] || die "$ROOT/bin/mage is not executable; not pointing Mage at it"
  PREV=$(defaults read "$DEFAULTS_DOMAIN" MageRootOverride 2>/dev/null || true)
  [ -z "$PREV" ] || [ "$PREV" = "$ROOT" ] || info "previous MageRootOverride: $PREV"
  run defaults write "$DEFAULTS_DOMAIN" MageRootOverride -string "$ROOT"
  if [ "$DRY" != 1 ]; then
    [ "$(defaults read "$DEFAULTS_DOMAIN" MageRootOverride 2>/dev/null)" = "$ROOT" ] || die "MageRootOverride did not read back as $ROOT"
    [ -z "$PREV" ] || [ "$PREV" = "$ROOT" ] || printf '%s\n' "$PREV" > "$STATE/MageRootOverride.previous-$TS"
    record "defaults $DEFAULTS_DOMAIN MageRootOverride = $ROOT (verified)"
  fi
fi

say "Done"
if [ "$DRY" != 1 ]; then
  /bin/rm -f "$STATE/incomplete"
  { echo "install-mage-first-run.sh run $TS (resolved: $RESOLVED)"; printf '%s' "$MANIFEST_LINES"; } > "$STATE/install-$TS.txt"
  info "versions and sha256s recorded in $STATE/install-$TS.txt"
fi
[ "$RESOLVED" = github ] || warn "pinned versions were used for part of this run (GitHub unreachable)"
info "Open Mage from $APP_DEST. ASTRIDER Demo is listed under the shared Steam bottle."
if [ "$DRY" = 0 ] && [ "$SKIP_STEAM" = 0 ]; then
  if [ "$LAUNCH_STEAM" = 1 ]; then
    info "Starting Steam: sign in, then install ASTRIDER Demo from the Steam window."
    "$WINE" 'C:\Program Files (x86)\Steam\steam.exe' -noverifyfiles -nobootstrapupdate \
      -cef-disable-sandbox -cef-disable-gpu -cef-disable-gpu-compositing >/dev/null 2>&1 &
  else
    info "Next: open Steam, sign in and install ASTRIDER Demo. To open Steam from Terminal:"
    info "  WINEPREFIX=\"$PREFIX\" \"$WINE\" 'C:\\Program Files (x86)\\Steam\\steam.exe'"
  fi
fi
