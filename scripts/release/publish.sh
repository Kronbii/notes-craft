#!/usr/bin/env bash
# Tags the current commit and publishes a GitHub release with the IPA attached.
#
# Usage: scripts/release/publish.sh X.Y.Z            (release, from main)
#        scripts/release/publish.sh X.Y.Z-beta.N     (development build, a pre-release)
# Build the IPA first with scripts/release/build-ipa.sh.
set -euo pipefail
cd "$(dirname "$0")/../.."
version="${1:?usage: publish.sh X.Y.Z[-beta.N]}"
tag="v$version"
base="${version%%-*}"
prerelease=false
[[ "$version" == *-* ]] && prerelease=true

if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$ ]]; then
  echo "error: version must look like 1.2.3 or 1.2.3-beta.1" >&2
  exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "error: commit or stash your changes first" >&2
  exit 1
fi
branch=$(git rev-parse --abbrev-ref HEAD)
if ! $prerelease && [ "$branch" != "main" ]; then
  echo "error: releases are published from main (you are on $branch)" >&2
  exit 1
fi
plist_version=$(python3 -c "import plistlib;print(plistlib.load(open('Resources/Info.plist','rb'))['CFBundleShortVersionString'])")
if [ "$plist_version" != "$base" ]; then
  echo "error: Resources/Info.plist says $plist_version, not $base (scripts/release/bump-version.sh)" >&2
  exit 1
fi
ipa="dist/NotesCraft-$base.ipa"
if [ ! -f "$ipa" ]; then
  echo "error: $ipa is missing; run scripts/release/build-ipa.sh" >&2
  exit 1
fi
asset="dist/NotesCraft-$version.ipa"
if [ "$asset" != "$ipa" ]; then
  cp "$ipa" "$asset"
fi
(cd dist && sha256sum "$(basename "$asset")" > "$(basename "$asset").sha256")

# Release notes: this version's section of the changelog.
notes=$(mktemp)
trap 'rm -f "$notes"' EXIT
awk -v v="$version" '
  $0 ~ "^## \\[" v "\\]" { on = 1; next }
  on && /^## \[/ { exit }
  on && /^\[[^]]+\]: / { exit }
  on { print }
' CHANGELOG.md > "$notes"
if ! grep -q '[^[:space:]]' "$notes"; then
  echo "error: CHANGELOG.md has no section for [$version]" >&2
  exit 1
fi
{
  echo
  echo "### Install"
  echo "Download \`$(basename "$asset")\` below and install it with xtool, SideStore, AltStore or Sideloadly. Updating keeps your notes. See the [README](https://github.com/Kronbii/notes-craft#install)."
} >> "$notes"

if ! git rev-parse "$tag" >/dev/null 2>&1; then
  git tag -a "$tag" -m "NotesCraft $version"
fi
git push origin "$tag"
flags=(--title "NotesCraft $version" --notes-file "$notes" --verify-tag)
if $prerelease; then flags+=(--prerelease); else flags+=(--latest); fi
gh release create "$tag" "$asset" "$asset.sha256" "${flags[@]}"
