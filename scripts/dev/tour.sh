#!/usr/bin/env bash
# Usage: tour.sh SCENARIO [TIMEOUT_SECONDS]
# Sends a tour command to NotesCraft on the iPad, waits for it to finish and
# pulls the screenshots into scratchpad/tours/<run>.
set -euo pipefail
TOOLS="$(cd "$(dirname "$0")" && pwd)"
BASE="${TOUR_OUT:-/tmp/notescraft-tours}"
. "$TOOLS/common.sh"
if [ -z "$NC_APP_ID" ]; then
  echo "Set NC_APP_ID (see scripts/dev/common.sh)" >&2
  exit 1
fi
SCENARIO="$1"
TIMEOUT="${2:-600}"

before=$($AFC ls /Documents/Automation/out 2>/dev/null | sort || true)
printf '{"scenario":"%s"}' "$SCENARIO" > "$TOOLS/command.json"
$AFC mkdir /Documents/Automation >/dev/null 2>&1 || true
$AFC put "$TOOLS/command.json" /Documents/Automation/command.json >/dev/null

# Wait for a new run folder with a DONE marker.
deadline=$((SECONDS + TIMEOUT))
run=""
while [ $SECONDS -lt $deadline ]; do
  sleep 3
  after=$($AFC ls /Documents/Automation/out 2>/dev/null | sort || true)
  run=$(comm -13 <(echo "$before") <(echo "$after") | grep "^$SCENARIO-" | tail -1 || true)
  if [ -n "$run" ] && $AFC ls "/Documents/Automation/out/$run" | grep -q '^DONE$'; then
    break
  fi
done
if [ -z "$run" ]; then
  # Don't leave the command behind: the app would run it whenever it is next opened.
  $AFC rm /Documents/Automation/command.json >/dev/null 2>&1 || true
  echo "no run started (is the app open in the foreground?)"
  exit 1
fi
mkdir -p "$BASE/tours"
$AFC pull "/Documents/Automation/out/$run" "$BASE/tours/$run"
echo "$BASE/tours/$run"
ls "$BASE/tours/$run" | head -80
