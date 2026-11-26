#!/usr/bin/env bash
# Sets the app version (CFBundleShortVersionString) and raises the build number
# (CFBundleVersion) by one, or sets it explicitly.
#
# Usage: scripts/release/bump-version.sh 1.1.0 [build]
set -euo pipefail
cd "$(dirname "$0")/../.."
version="${1:?usage: bump-version.sh X.Y.Z [build]}"
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: the app version must be X.Y.Z (pre-release suffixes go only on the tag)" >&2
  exit 1
fi
python3 - "$version" "${2:-}" <<'PY'
import plistlib, sys
path = "Resources/Info.plist"
with open(path, "rb") as f:
    info = plistlib.load(f)
old = (info["CFBundleShortVersionString"], info["CFBundleVersion"])
build = sys.argv[2] or str(int(info["CFBundleVersion"]) + 1)
if int(build) <= int(old[1]):
    sys.exit(f"error: build {build} must be higher than {old[1]}")
info["CFBundleShortVersionString"] = sys.argv[1]
info["CFBundleVersion"] = build
with open(path, "wb") as f:
    plistlib.dump(info, f)
print(f"{old[0]} ({old[1]}) -> {sys.argv[1]} ({build})")
PY
