#!/bin/sh
# Build tripwire and run it as a LaunchAgent.
# Usage: scripts/install.sh          real mode (5 min window, 90 min block)
#        scripts/install.sh --test   test mode (30 s window, no block)
set -eu

usage() {
  cat <<'EOF'
Usage: scripts/install.sh [--test]

Install tripwire in real mode, or use --test for a 30 second window with no
SelfControl block.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

case "$#:$*" in
  0:) MODE_ARG="" ;;
  1:--test) MODE_ARG="<string>--test</string>" ;;
  1:--help|1:-h) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
cd "$ROOT_DIR"

LABEL=com.aaqifz.tripwire
BIN_DIR=${HOME:?HOME must be set}/.local/bin
STATE_DIR=${HOME:?HOME must be set}/.tripwire
LAUNCH_AGENTS_DIR=${HOME:?HOME must be set}/Library/LaunchAgents
BIN="$BIN_DIR/tripwire"
PLIST="$LAUNCH_AGENTS_DIR/$LABEL.plist"
HEARTBEAT="$STATE_DIR/heartbeat"
DOMAIN="gui/$(id -u)/$LABEL"

# Tests can shorten waits without changing the production defaults.
UNLOAD_ATTEMPTS=${TRIPWIRE_UNLOAD_ATTEMPTS:-20}
UNLOAD_INTERVAL=${TRIPWIRE_UNLOAD_INTERVAL:-0.5}
HEALTH_ATTEMPTS=${TRIPWIRE_HEALTH_ATTEMPTS:-20}
HEALTH_INTERVAL=${TRIPWIRE_HEALTH_INTERVAL:-0.5}

case "$UNLOAD_ATTEMPTS:$HEALTH_ATTEMPTS" in
  *[!0-9:]*|:*) die "wait attempt counts must be non-negative integers" ;;
esac

is_number() {
  case "$1" in
    ""|.|*.*.*|*.) return 1 ;;
    *[!0-9.]*) return 1 ;;
  esac
  return 0
}
is_number "$UNLOAD_INTERVAL" || die "unload wait interval must be a non-negative number"
is_number "$HEALTH_INTERVAL" || die "health wait interval must be a non-negative number"

case "${TRIPWIRE_SWIFTPM_DISABLE_SANDBOX:-}" in
  ""|1) ;;
  *) die "TRIPWIRE_SWIFTPM_DISABLE_SANDBOX must be 1 when set" ;;
esac

stage=""
plist_stage=""
backup_dir=""
old_bin=0
old_plist=0
service_was_loaded=0
old_service_needs_restart=0
replacement_bootstrapped=0
service_stop_pending=0
mutation_started=0
preserve_backup=0

cleanup() {
  [ -z "$stage" ] || rm -f "$stage"
  [ -z "$plist_stage" ] || rm -f "$plist_stage"
  if [ -n "$backup_dir" ] && [ "$preserve_backup" -eq 0 ]; then
    rm -rf "$backup_dir"
  fi
}
trap cleanup EXIT

service_loaded() {
  launchctl print "$DOMAIN" >/dev/null 2>&1
}

wait_for_unload() {
  i=0
  while service_loaded; do
    [ "$i" -lt "$UNLOAD_ATTEMPTS" ] || return 1
    sleep "$UNLOAD_INTERVAL"
    i=$((i + 1))
  done
  return 0
}

restart_original_if_needed() {
  [ "$old_service_needs_restart" -eq 1 ] || return 0
  [ -f "$PLIST" ] || return 1

  # If bootout is still completing, wait before deciding whether a restart is
  # needed. Never bootstrap while the old job still appears loaded.
  if [ "$service_stop_pending" -eq 1 ]; then
    wait_for_unload >/dev/null 2>&1 || true
  fi
  service_stop_pending=0
  service_loaded && return 0
  launchctl bootstrap "gui/$(id -u)" "$PLIST" >/dev/null 2>&1
}

process_healthy() {
  info=$(launchctl print "$DOMAIN" 2>/dev/null) || return 1
  pid=$(printf '%s\n' "$info" | sed -n 's/^[[:space:]]*pid = //p' | head -n 1)
  case "$pid" in
    ""|0|*[!0-9]*) return 1 ;;
  esac
  last_exit=$(printf '%s\n' "$info" | sed -n 's/^[[:space:]]*last exit code = //p' | head -n 1)
  case "$last_exit" in
    ""|0|0x0|0x00000000|"(never exited)") return 0 ;;
    *) return 1 ;;
  esac
}

heartbeat_fresh() {
  [ -f "$HEARTBEAT" ] || return 1
  mtime=$(stat -f %m "$HEARTBEAT" 2>/dev/null) || return 1
  now=$(date +%s) || return 1
  [ "$mtime" -le "$now" ] || return 1
  [ "$((now - mtime))" -le 30 ]
}

wait_for_health() {
  i=0
  while :; do
    if heartbeat_fresh && process_healthy; then
      return 0
    fi
    [ "$i" -lt "$HEALTH_ATTEMPTS" ] || return 1
    sleep "$HEALTH_INTERVAL"
    i=$((i + 1))
  done
}

rollback() {
  # Rollback must make a best effort even when the original failure was a
  # launchctl or filesystem error. Preserve the original exit status.
  trap - INT TERM HUP
  set +e

  # A stop failure before any swap leaves the original files untouched. Do not
  # remove them or bootstrap a second copy of the original service.
  if [ "$mutation_started" -eq 0 ]; then
    set -e
    return 0
  fi

  if service_loaded; then
    if ! launchctl bootout "$DOMAIN" >/dev/null 2>&1; then
      echo "error: could not stop the replacement LaunchAgent; new files and rollback data were kept" >&2
      preserve_backup=1
      set -e
      return 1
    fi
    if ! wait_for_unload >/dev/null 2>&1; then
      echo "error: replacement LaunchAgent did not stop; new files and rollback data were kept" >&2
      preserve_backup=1
      set -e
      return 1
    fi
  fi

  if ! rm -f "$BIN" "$PLIST"; then
    echo "error: could not remove the failed replacement; rollback data was kept" >&2
    preserve_backup=1
    set -e
    return 1
  fi
  if [ "$old_bin" -eq 1 ] && ! mv "$backup_dir/bin" "$BIN"; then
    echo "error: could not restore the previous binary; rollback data was kept" >&2
    preserve_backup=1
    set -e
    return 1
  fi
  if [ "$old_plist" -eq 1 ] && ! mv "$backup_dir/plist" "$PLIST"; then
    echo "error: could not restore the previous LaunchAgent; rollback data was kept" >&2
    preserve_backup=1
    set -e
    return 1
  fi

  if [ "$old_service_needs_restart" -eq 1 ] && [ -f "$PLIST" ]; then
    if ! launchctl bootstrap "gui/$(id -u)" "$PLIST" >/dev/null 2>&1; then
      echo "error: previous files were restored but the previous LaunchAgent did not restart; rollback data was kept" >&2
      preserve_backup=1
      set -e
      return 1
    fi
  fi

  replacement_bootstrapped=0
  service_stop_pending=0
  preserve_backup=0
  set -e
  return 0
}

fail_install() {
  message=$1
  if [ "$mutation_started" -eq 1 ]; then
    echo "error: $message; restoring the previous installation" >&2
    if ! rollback; then
      echo "error: rollback incomplete; inspect the retained rollback directory: $backup_dir" >&2
    fi
  else
    echo "error: $message; existing installation was left untouched" >&2
    if [ "$service_stop_pending" -eq 1 ] || [ "$service_was_loaded" -eq 1 ]; then
      if ! restart_original_if_needed; then
        preserve_backup=1
        echo "error: the previous LaunchAgent remains stopped; rollback data was kept at $backup_dir" >&2
      fi
    fi
  fi
  exit 1
}

on_signal() {
  signal=$1
  trap - INT TERM HUP
  if [ "$mutation_started" -eq 1 ]; then
    fail_install "interrupted by SIG$signal"
  else
    fail_install "interrupted by SIG$signal"
  fi
}
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
trap 'on_signal HUP' HUP

echo "building tripwire..."
if [ "${TRIPWIRE_SWIFTPM_DISABLE_SANDBOX:-}" = 1 ]; then
  swift build -c release --disable-sandbox
else
  swift build -c release
fi
[ -x .build/release/tripwire ] || die "swift build did not produce .build/release/tripwire"

# Prepare all files before stopping the current service. The binary stage is
# in the destination directory so mv below is an atomic same-filesystem swap.
mkdir -p "$BIN_DIR" "$STATE_DIR" "$LAUNCH_AGENTS_DIR"
stage=$(mktemp "$BIN_DIR/.$LABEL.binary.XXXXXX") || die "cannot create a binary staging file"
cp .build/release/tripwire "$stage" || die "cannot stage the built binary"
chmod 755 "$stage" || die "cannot make the staged binary executable"

# Keep the same path on each install: macOS grants permissions per binary path.
# The fixed certificate keeps Input Monitoring access across rebuilds.
if security find-identity -p codesigning 2>/dev/null | grep -q '\"tripwire-local\"'; then
  codesign --force --sign tripwire-local --identifier "$LABEL" "$stage" || die "codesign failed"
else
  if ! "$SCRIPT_DIR/make-signing-cert.sh"; then
    echo "warning: could not create tripwire-local; using an ad-hoc signature" >&2
  fi
  if security find-identity -p codesigning 2>/dev/null | grep -q '\"tripwire-local\"'; then
    codesign --force --sign tripwire-local --identifier "$LABEL" "$stage" || die "codesign failed"
  else
    echo "warning: no tripwire-local certificate. Each rebuild will need Input Monitoring again." >&2
    codesign --force --sign - --identifier "$LABEL" "$stage" || die "ad-hoc codesign failed"
  fi
fi
codesign --verify --strict "$stage" >/dev/null 2>&1 || die "codesign verification failed"

plist_stage=$(mktemp "$LAUNCH_AGENTS_DIR/.$LABEL.plist.XXXXXX") || die "cannot create a LaunchAgent staging file"
cat > "$plist_stage" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN</string><string>run</string>$MODE_ARG</array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardErrorPath</key><string>$STATE_DIR/tripwire.err</string>
</dict>
</plist>
EOF
chmod 600 "$plist_stage" || die "cannot protect the staged LaunchAgent"

backup_dir=$(mktemp -d "$BIN_DIR/.$LABEL.rollback.XXXXXX") || die "cannot create a rollback directory"
if [ -e "$BIN" ]; then
  cp -p "$BIN" "$backup_dir/bin" || die "cannot back up the current binary"
  old_bin=1
fi
if [ -e "$PLIST" ]; then
  cp -p "$PLIST" "$backup_dir/plist" || die "cannot back up the current LaunchAgent"
  old_plist=1
fi
if service_loaded; then
  service_was_loaded=1
  old_service_needs_restart=1
  service_stop_pending=1
  launchctl bootout "$DOMAIN" || fail_install "cannot stop the current LaunchAgent"
  wait_for_unload || fail_install "the current LaunchAgent did not stop in time"
  service_stop_pending=0
fi

# The service is stopped. Replace both files with same-directory renames.
mutation_started=1
if [ "$old_bin" -eq 1 ]; then mv "$BIN" "$backup_dir/old-live-bin" || fail_install "cannot move the current binary"; fi
if [ "$old_plist" -eq 1 ]; then mv "$PLIST" "$backup_dir/old-live-plist" || fail_install "cannot move the current LaunchAgent"; fi
mv "$stage" "$BIN" || fail_install "cannot install the new binary"
stage=""
mv "$plist_stage" "$PLIST" || fail_install "cannot install the new LaunchAgent"
plist_stage=""

# A previous heartbeat is not proof that the newly bootstrapped process runs.
rm -f "$HEARTBEAT" || fail_install "cannot clear the previous heartbeat"

if ! launchctl bootstrap "gui/$(id -u)" "$PLIST"; then
  fail_install "launchctl bootstrap failed"
fi
replacement_bootstrapped=1
if ! wait_for_health; then
  fail_install "tripwire did not write a fresh heartbeat from a live process"
fi

[ -x /Applications/SelfControl.app/Contents/MacOS/selfcontrol-cli ] || echo "warning: SelfControl is not in /Applications. Tripwire cannot block until you install it."
echo "tripwire installed${MODE_ARG:+ (test mode)}. Log: $STATE_DIR/tripwire.err"
