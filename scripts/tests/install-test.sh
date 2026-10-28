#!/bin/sh
# Exercise install/uninstall transaction paths with mocked macOS commands.
# This never runs tripwire, launchctl, codesign, or SelfControl for real.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SOURCE_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/tripwire-installer-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

FAKE_REPO="$TEST_ROOT/repo"
FAKE_BIN="$TEST_ROOT/bin"
HOME_DIR="$TEST_ROOT/home"
mkdir -p "$FAKE_REPO/scripts" "$FAKE_BIN" "$HOME_DIR"
cp "$SOURCE_ROOT/scripts/install.sh" "$FAKE_REPO/scripts/install.sh"
cp "$SOURCE_ROOT/scripts/uninstall.sh" "$FAKE_REPO/scripts/uninstall.sh"
chmod 755 "$FAKE_REPO/scripts/install.sh" "$FAKE_REPO/scripts/uninstall.sh"
cat > "$FAKE_REPO/scripts/make-signing-cert.sh" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod 755 "$FAKE_REPO/scripts/make-signing-cert.sh"

cat > "$FAKE_BIN/swift" <<'EOF'
#!/bin/sh
set -eu
[ "${FAKE_SWIFT_FAIL:-0}" = 1 ] && exit 1
mkdir -p .build/release
printf '%s\n' "new binary" > .build/release/tripwire
chmod 755 .build/release/tripwire
EOF

cat > "$FAKE_BIN/security" <<'EOF'
#!/bin/sh
printf '  1) FAKE "tripwire-local"\n'
EOF

cat > "$FAKE_BIN/codesign" <<'EOF'
#!/bin/sh
[ "${FAKE_CODESIGN_FAIL:-0}" = 1 ] && exit 1
exit 0
EOF

cat > "$FAKE_BIN/launchctl" <<'EOF'
#!/bin/sh
set -eu
state="${HOME}/.fake-launchctl-loaded"
case "$1" in
  print)
    if [ -f "${HOME}/.fake-send-term" ] && [ ! -f "${HOME}/.fake-term-sent" ]; then
      : > "${HOME}/.fake-term-sent"
      kill -TERM "$PPID" || true
    fi
    [ -f "$state" ] || exit 1
    printf 'state = running\npid = 4242\nlast exit code = 0\n'
    ;;
  bootout)
    if [ "${FAKE_BOOTOUT_FAIL:-0}" = 1 ]; then exit 1; fi
    if [ "${FAKE_BOOTOUT_STICKY:-0}" = 1 ]; then exit 0; fi
    if [ "${FAKE_BOOTOUT_STICKY_AFTER_BOOTSTRAP:-0}" = 1 ] && [ -f "${HOME}/.fake-bootstrap-failed" ]; then exit 1; fi
    rm -f "$state"
    if [ "${FAKE_SEND_TERM_AFTER_BOOTOUT:-0}" = 1 ]; then
      : > "${HOME}/.fake-send-term"
    fi
    ;;
  bootstrap)
    count_file="${HOME}/.fake-launchctl-bootstrap-count"
    count=0
    [ -f "$count_file" ] && count=$(cat "$count_file")
    count=$((count + 1))
    printf '%s\n' "$count" > "$count_file"
    if [ "${FAKE_BOOTSTRAP_FAIL_AND_STICKY:-0}" = 1 ] && [ "$count" -eq 1 ]; then
      : > "$state"
      : > "${HOME}/.fake-bootstrap-failed"
      exit 1
    fi
    if [ "${FAKE_BOOTSTRAP_FAIL_ONCE:-0}" = 1 ] && [ "$count" -eq 1 ]; then exit 1; fi
    : > "$state"
    if [ "${FAKE_HEALTH_FAIL:-0}" != 1 ]; then
      mkdir -p "$HOME/.tripwire"
      : > "$HOME/.tripwire/heartbeat"
    fi
    ;;
  *) exit 2 ;;
esac
EOF

chmod 755 "$FAKE_BIN"/*
PATH="$FAKE_BIN:$PATH"
export PATH HOME_DIR

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_file() { [ -e "$1" ] || fail "expected file: $1"; }
assert_no_file() { [ ! -e "$1" ] || fail "unexpected file: $1"; }
assert_contains() { grep -q "$2" "$1" || fail "expected '$2' in $1"; }
inode() { stat -f %i "$1"; }
run_install() {
  HOME="$HOME_DIR" TRIPWIRE_UNLOAD_ATTEMPTS=2 TRIPWIRE_UNLOAD_INTERVAL=0 \
    TRIPWIRE_HEALTH_ATTEMPTS=2 TRIPWIRE_HEALTH_INTERVAL=0 \
    "$FAKE_REPO/scripts/install.sh" "$@"
}

# Invalid options fail before build or filesystem setup.
if HOME="$HOME_DIR" "$FAKE_REPO/scripts/install.sh" --bogus >/dev/null 2>&1; then
  fail "unknown option was accepted"
fi
assert_no_file "$HOME_DIR/.local"

# A clean test-mode install stages, bootstraps, and verifies a heartbeat.
run_install --test >/dev/null
assert_file "$HOME_DIR/.local/bin/tripwire"
assert_file "$HOME_DIR/Library/LaunchAgents/com.aaqifz.tripwire.plist"
assert_file "$HOME_DIR/.tripwire/heartbeat"
assert_contains "$HOME_DIR/Library/LaunchAgents/com.aaqifz.tripwire.plist" '<string>--test</string>'

# Build and signing failures happen before launchd is touched.
printf '%s\n' old > "$HOME_DIR/.local/bin/tripwire"
printf '%s\n' old-plist > "$HOME_DIR/Library/LaunchAgents/com.aaqifz.tripwire.plist"
: > "$HOME_DIR/.fake-launchctl-loaded"
old_inode=$(inode "$HOME_DIR/.local/bin/tripwire")
if HOME="$HOME_DIR" FAKE_SWIFT_FAIL=1 "$FAKE_REPO/scripts/install.sh" >/dev/null 2>&1; then
  fail "build failure was reported as success"
fi
assert_contains "$HOME_DIR/.local/bin/tripwire" '^old$'
[ "$(inode "$HOME_DIR/.local/bin/tripwire")" = "$old_inode" ] || fail "build failure changed the live binary"
assert_file "$HOME_DIR/.fake-launchctl-loaded"
if HOME="$HOME_DIR" FAKE_CODESIGN_FAIL=1 "$FAKE_REPO/scripts/install.sh" >/dev/null 2>&1; then
  fail "signing failure was reported as success"
fi
assert_contains "$HOME_DIR/.local/bin/tripwire" '^old$'
[ "$(inode "$HOME_DIR/.local/bin/tripwire")" = "$old_inode" ] || fail "signing failure changed the live binary"
assert_file "$HOME_DIR/.fake-launchctl-loaded"

# A stop timeout preserves the old files and their inode before any swap.
if HOME="$HOME_DIR" FAKE_BOOTOUT_STICKY=1 TRIPWIRE_UNLOAD_ATTEMPTS=2 TRIPWIRE_UNLOAD_INTERVAL=0 \
  TRIPWIRE_HEALTH_ATTEMPTS=2 TRIPWIRE_HEALTH_INTERVAL=0 "$FAKE_REPO/scripts/install.sh" >/dev/null 2>&1; then
  fail "stop timeout was reported as success"
fi
assert_contains "$HOME_DIR/.local/bin/tripwire" '^old$'
[ "$(inode "$HOME_DIR/.local/bin/tripwire")" = "$old_inode" ] || fail "stop timeout changed the live binary"
assert_contains "$HOME_DIR/Library/LaunchAgents/com.aaqifz.tripwire.plist" '^old-plist$'
assert_file "$HOME_DIR/.fake-launchctl-loaded"

# A signal after bootout but before the file swap restarts the old service.
SIGNAL_HOME="$TEST_ROOT/home-signal"
mkdir -p "$SIGNAL_HOME/.local/bin" "$SIGNAL_HOME/Library/LaunchAgents"
printf '%s\n' old > "$SIGNAL_HOME/.local/bin/tripwire"
printf '%s\n' old-plist > "$SIGNAL_HOME/Library/LaunchAgents/com.aaqifz.tripwire.plist"
: > "$SIGNAL_HOME/.fake-launchctl-loaded"
if HOME="$SIGNAL_HOME" FAKE_SEND_TERM_AFTER_BOOTOUT=1 TRIPWIRE_UNLOAD_ATTEMPTS=2 TRIPWIRE_UNLOAD_INTERVAL=0 \
  TRIPWIRE_HEALTH_ATTEMPTS=2 TRIPWIRE_HEALTH_INTERVAL=0 "$FAKE_REPO/scripts/install.sh" >/dev/null 2>&1; then
  fail "signal during unload was reported as success"
fi
assert_contains "$SIGNAL_HOME/.local/bin/tripwire" '^old$'
assert_contains "$SIGNAL_HOME/Library/LaunchAgents/com.aaqifz.tripwire.plist" '^old-plist$'
assert_file "$SIGNAL_HOME/.fake-launchctl-loaded"
[ "$(cat "$SIGNAL_HOME/.fake-launchctl-bootstrap-count")" = 1 ] || fail "signal path bootstrapped more than once"

# A bootstrap failure restores the previous binary, plist, and loaded service.
printf '%s\n' old > "$HOME_DIR/.local/bin/tripwire"
printf '%s\n' old-plist > "$HOME_DIR/Library/LaunchAgents/com.aaqifz.tripwire.plist"
: > "$HOME_DIR/.fake-launchctl-loaded"
rm -f "$HOME_DIR/.fake-launchctl-bootstrap-count"
if HOME="$HOME_DIR" FAKE_BOOTSTRAP_FAIL_ONCE=1 TRIPWIRE_UNLOAD_ATTEMPTS=2 TRIPWIRE_UNLOAD_INTERVAL=0 \
  TRIPWIRE_HEALTH_ATTEMPTS=2 TRIPWIRE_HEALTH_INTERVAL=0 "$FAKE_REPO/scripts/install.sh" >/dev/null 2>&1; then
  fail "bootstrap failure was reported as success"
fi
assert_contains "$HOME_DIR/.local/bin/tripwire" '^old$'
assert_contains "$HOME_DIR/Library/LaunchAgents/com.aaqifz.tripwire.plist" '^old-plist$'
assert_file "$HOME_DIR/.fake-launchctl-loaded"

# A health timeout also restores the previous installation.
if HOME="$HOME_DIR" FAKE_HEALTH_FAIL=1 TRIPWIRE_UNLOAD_ATTEMPTS=2 TRIPWIRE_UNLOAD_INTERVAL=0 \
  TRIPWIRE_HEALTH_ATTEMPTS=2 TRIPWIRE_HEALTH_INTERVAL=0 "$FAKE_REPO/scripts/install.sh" >/dev/null 2>&1; then
  fail "health timeout was reported as success"
fi
assert_contains "$HOME_DIR/.local/bin/tripwire" '^old$'
assert_contains "$HOME_DIR/Library/LaunchAgents/com.aaqifz.tripwire.plist" '^old-plist$'
assert_file "$HOME_DIR/.fake-launchctl-loaded"

# If the replacement cannot stop, keep the live replacement and rollback data.
STICKY_HOME="$TEST_ROOT/home-sticky"
mkdir -p "$STICKY_HOME/.local/bin" "$STICKY_HOME/Library/LaunchAgents"
printf '%s\n' old > "$STICKY_HOME/.local/bin/tripwire"
printf '%s\n' old-plist > "$STICKY_HOME/Library/LaunchAgents/com.aaqifz.tripwire.plist"
: > "$STICKY_HOME/.fake-launchctl-loaded"
rm -f "$STICKY_HOME/.fake-launchctl-bootstrap-count"
if HOME="$STICKY_HOME" FAKE_BOOTSTRAP_FAIL_AND_STICKY=1 FAKE_BOOTOUT_STICKY_AFTER_BOOTSTRAP=1 \
  TRIPWIRE_UNLOAD_ATTEMPTS=2 TRIPWIRE_UNLOAD_INTERVAL=0 TRIPWIRE_HEALTH_ATTEMPTS=2 TRIPWIRE_HEALTH_INTERVAL=0 \
  "$FAKE_REPO/scripts/install.sh" >/dev/null 2>&1; then
  fail "sticky bootstrap failure was reported as success"
fi
assert_contains "$STICKY_HOME/.local/bin/tripwire" '^new binary$'
assert_file "$STICKY_HOME/.fake-launchctl-loaded"
rollback_dirs=$(find "$STICKY_HOME/.local/bin" -type d -name '.com.aaqifz.tripwire.rollback.*' -print)
[ -n "$rollback_dirs" ] || fail "failed rollback removed its recovery directory"
assert_file "$rollback_dirs/bin"
assert_contains "$rollback_dirs/bin" '^old$'

# Uninstall waits, then removes the files. A failed bootout keeps them.
HOME="$HOME_DIR" TRIPWIRE_UNLOAD_ATTEMPTS=2 TRIPWIRE_UNLOAD_INTERVAL=0 \
  "$FAKE_REPO/scripts/uninstall.sh" >/dev/null
assert_no_file "$HOME_DIR/.local/bin/tripwire"
assert_no_file "$HOME_DIR/Library/LaunchAgents/com.aaqifz.tripwire.plist"

mkdir -p "$HOME_DIR/.local/bin" "$HOME_DIR/Library/LaunchAgents"
: > "$HOME_DIR/.local/bin/tripwire"
: > "$HOME_DIR/Library/LaunchAgents/com.aaqifz.tripwire.plist"
: > "$HOME_DIR/.fake-launchctl-loaded"
if HOME="$HOME_DIR" FAKE_BOOTOUT_FAIL=1 TRIPWIRE_UNLOAD_ATTEMPTS=2 TRIPWIRE_UNLOAD_INTERVAL=0 \
  "$FAKE_REPO/scripts/uninstall.sh" >/dev/null 2>&1; then
  fail "bootout failure was reported as success"
fi
assert_file "$HOME_DIR/.local/bin/tripwire"
assert_file "$HOME_DIR/Library/LaunchAgents/com.aaqifz.tripwire.plist"

echo "installer integration tests passed"
