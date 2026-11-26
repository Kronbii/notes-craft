#!/usr/bin/env bash
# Builds the release IPA for distribution: dist/NotesCraft-<version>.ipa
#
# The IPA is unsigned (people sign it for their own device when they install it
# with xtool, AltStore, SideStore or Sideloadly). Build-machine details are
# removed: the absolute toolchain library path and debug-info file paths.
set -euo pipefail
cd "$(dirname "$0")/../.."

version=$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist 2>/dev/null \
  || python3 -c "import plistlib;print(plistlib.load(open('Resources/Info.plist','rb'))['CFBundleShortVersionString'])")
build=$(python3 -c "import plistlib;print(plistlib.load(open('Resources/Info.plist','rb'))['CFBundleVersion'])")

tool() {
  for name in "$1" "$1-18" "$1-19" "$1-17"; do
    if command -v "$name" >/dev/null 2>&1; then echo "$name"; return; fi
  done
  echo "missing $1 (install llvm)" >&2
  exit 1
}
STRIP=$(tool llvm-strip)
INT=$(tool llvm-install-name-tool)
OBJDUMP=$(tool llvm-objdump)

echo "Building NotesCraft $version ($build), release configuration…"
xtool dev build --configuration release --ipa >/dev/null

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
(cd "$work" && unzip -q "$OLDPWD/xtool/NotesCraft.ipa")
bin="$work/Payload/NotesCraft.app/NotesCraft"

# Library search paths that point at the build machine.
"$OBJDUMP" --macho --private-headers "$bin" | awk '/cmd LC_RPATH/{r=1} r&&/path /{print $2; r=0}' | while read -r rpath; do
  case "$rpath" in
    @*|/usr/lib/*) ;;
    *) "$INT" -delete_rpath "$rpath" "$bin" ;;
  esac
done
# Debug info (it records source file paths); symbol names stay for crash reports.
"$STRIP" -S "$bin"

if strings "$bin" | grep -q "$HOME"; then
  echo "error: the binary still mentions $HOME" >&2
  exit 1
fi

mkdir -p dist
out="dist/NotesCraft-$version.ipa"
rm -f "$out"
(cd "$work" && zip -qry "$OLDPWD/$out" Payload)
sha=$(sha256sum "$out" | cut -d' ' -f1)
echo "$sha  $(basename "$out")" > "$out.sha256"
echo "$out ($(du -h "$out" | cut -f1)), sha256 $sha"
