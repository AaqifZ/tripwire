#!/bin/sh
# Stop tripwire and remove the LaunchAgent and binary. Keeps ~/.tripwire (the event log).
# A running SelfControl block is not affected.
set -eu

LABEL=com.aaqifz.tripwire
BIN=${HOME:?HOME must be set}/.local/bin/tripwire
PLIST=${HOME:?HOME must be set}/Library/LaunchAgents/$LABEL.plist
DOMAIN="gui/$(id -u)/$LABEL"
ATTEMPTS=${TRIPWIRE_UNLOAD_ATTEMPTS:-20}
INTERVAL=${TRIPWIRE_UNLOAD_INTERVAL:-0.5}

case "$ATTEMPTS" in
  *[!0-9]*) echo "error: wait attempt count must be a non-negative integer" >&2; exit 2 ;;
esac
case "$INTERVAL" in
  ""|*[!0-9.]*) echo "error: wait interval must be a non-negative number" >&2; exit 2 ;;
esac

loaded() {
  launchctl print "$DOMAIN" >/dev/null 2>&1
}

wait_for_unload() {
  i=0
  while loaded; do
    [ "$i" -lt "$ATTEMPTS" ] || return 1
    sleep "$INTERVAL"
    i=$((i + 1))
  done
}

if loaded; then
  if ! launchctl bootout "$DOMAIN"; then
    echo "error: launchctl could not stop $LABEL; files were kept" >&2
    exit 1
  fi
  if ! wait_for_unload; then
    echo "error: $LABEL did not stop in time; files were kept" >&2
    exit 1
  fi
fi

rm -f "$PLIST" "$BIN"
echo "tripwire removed. Event log kept in ~/.tripwire/"
