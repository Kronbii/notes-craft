#!/usr/bin/env bash
# Build and install NotesCraft on the USB-connected iPad.
#
# Why installs used to hang at "[Installing] 100%": iOS will not replace an app
# that is open on screen. The installer asks RunningBoard to stop it, the request
# "failed due to termination resistance", and the installer then waits for the app
# to exit on its own, so xtool waits forever. This script first asks the running
# app to save and quit (a "quit" automation command over USB), and if an install
# still stalls it asks again and then tells you to close the app by hand.
#
# Usage: scripts/dev/install.sh [path/to/NotesCraft.ipa]
# Without an argument it builds a debug IPA first.
set -u
cd "$(dirname "$0")/../.." || exit 1
. scripts/dev/common.sh
IPA="${1:-}"

quit_app() {
  [ -n "$NC_APP_ID" ] || return 0
  local cmd
  cmd=$(mktemp)
  printf '{"scenario":"quit"}' > "$cmd"
  if ! $AFC put "$cmd" /Documents/Automation/command.json >/dev/null 2>&1; then rm -f "$cmd"; return; fi
  rm -f "$cmd"
  for _ in 1 2 3 4 5 6 7 8; do
    sleep 1
    if ! $AFC ls /Documents/Automation 2>/dev/null | grep -qx "command.json"; then
      echo "asked NotesCraft to save and quit"
      sleep 2
      return
    fi
  done
  # Not open (or an older build without the command): don't leave it behind,
  # or the app would quit the next time it is opened.
  $AFC rm /Documents/Automation/command.json >/dev/null 2>&1
}

if [ -z "$IPA" ]; then
  xtool dev build --ipa 2>&1 | tail -1
  IPA=xtool/NotesCraft.ipa
fi
for attempt in 1 2 3; do
  quit_app
  log=$(mktemp)
  script -qfec "xtool install --usb '$IPA'" "$log" >/dev/null 2>&1 &
  pid=$!
  start=$SECONDS
  stalled_since=""
  asked_again=""
  result="timeout"
  while kill -0 "$pid" 2>/dev/null; do
    sleep 5
    out=$(tr '\r' '\n' < "$log" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g')
    if grep -q "Successfully installed" <<<"$out"; then result="ok"; break; fi
    if grep -q "^Error" <<<"$out"; then result="error"; break; fi
    last=$(grep -E "^\[" <<<"$out" | tail -1)
    if [[ "$last" == "[Installing] 100%" ]]; then
      stalled_since=${stalled_since:-$SECONDS}
      if (( SECONDS - stalled_since > 20 )) && [[ -z "$asked_again" ]]; then
        asked_again=1
        quit_app
      fi
      if (( SECONDS - stalled_since > 120 )); then result="stalled"; break; fi
    else
      stalled_since=""
    fi
    if (( SECONDS - start > 1500 )); then break; fi
  done
  pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null
  echo "attempt $attempt: $result ($(( SECONDS - start ))s) $(grep -E '^\[' <(tr '\r' '\n' < "$log" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g') | tail -1)"
  [[ "$result" == "error" ]] && tr '\r' '\n' < "$log" | grep -E "^Error" | head -3
  rm -f "$log"
  [[ "$result" == "ok" ]] && exit 0
  [[ "$result" == "stalled" ]] && echo "the iPad is waiting for NotesCraft to close: swipe up to the Home Screen (or close it in the app switcher)"
done
exit 1
