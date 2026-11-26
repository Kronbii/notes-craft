# shellcheck shell=bash
# Shared settings for the on-device scripts.
#
# NC_APP_ID is the bundle ID NotesCraft has on your iPad. xtool installs it as
# "XTL-<your Apple team ID>.<bundleID from xtool.yml>", for example
# XTL-AB12CD34EF.com.kronbii.NotesCraft. Put it in scripts/dev/local.env (not
# committed) as:  NC_APP_ID=XTL-AB12CD34EF.com.kronbii.NotesCraft
DEV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$DEV_DIR/local.env" ]; then
  # shellcheck disable=SC1091
  . "$DEV_DIR/local.env"
fi
NC_APP_ID="${NC_APP_ID:-}"
# shellcheck disable=SC2034 # used by the scripts that source this file
AFC="python3 -I $DEV_DIR/afcpull.py $NC_APP_ID"
