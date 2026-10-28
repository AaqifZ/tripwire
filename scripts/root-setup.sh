#!/bin/sh
# One-time root setup so a trip starts a block with no password dialog.
#   sudo scripts/root-setup.sh install   (run again after a SelfControl update or a site change)
#   sudo scripts/root-setup.sh remove
# The sudo rule allows one root-owned script. That script accepts only an end
# date within 95 minutes, and blocks only the root-owned copy of the site list.
set -eu

SRC=/Applications/SelfControl.app
DIR=/Library/Tripwire
APP=$DIR/SelfControl.app
BLOCK=$DIR/tripwire-block
LIST=$DIR/blocklist.selfcontrol
RULE=/etc/sudoers.d/tripwire
TEAM=EG6ZYP3AQH
MAX_SECONDS=5700

die() {
  echo "error: $*" >&2
  exit 1
}

[ "$(id -u)" -eq 0 ] || die "run with sudo"
USER_NAME=${SUDO_USER:-}
USER_ID=${SUDO_UID:-}
[ -n "$USER_NAME" ] && [ -n "$USER_ID" ] && [ "$USER_ID" -ne 0 ] || die "run with sudo from your own account"

verify_app() {
  codesign --verify --deep --strict "$1" 2>/dev/null || die "$1 failed the signature check"
  codesign -dv "$1/Contents/MacOS/selfcontrol-cli" 2>&1 | grep -qx "TeamIdentifier=$TEAM" \
    || die "$1 is not signed by the SelfControl team $TEAM"
}

remove() {
  rm -f "$RULE"
  rm -rf "$DIR"
}

case "${1:-}" in
  install) ;;
  remove) remove; echo "root setup removed. A trip shows a password dialog again."; exit 0 ;;
  *) echo "usage: sudo $0 install|remove" >&2; exit 2 ;;
esac

HOME_DIR=$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory | awk '{print $2}')
USER_LIST=$HOME_DIR/.tripwire/blocklist.selfcontrol
[ -f "$USER_LIST" ] || die "$USER_LIST is missing. Run tripwire once, then run this again"
[ "$(plutil -extract BlockAsWhitelist raw -o - "$USER_LIST")" = false ] || die "the blocklist is an allowlist"
plutil -extract HostBlacklist.0 raw -o - "$USER_LIST" >/dev/null || die "the blocklist has no sites"

verify_app "$SRC"
remove
mkdir -p "$DIR"
ditto "$SRC" "$APP"
plutil -convert binary1 -o "$LIST" "$USER_LIST"
cat > "$BLOCK" <<EOF
#!/bin/sh
# Installed by tripwire scripts/root-setup.sh. The only command the sudo rule allows.
set -eu
[ \$# -eq 1 ] || exit 64
case "\$1" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
  *) exit 64 ;;
esac
end=\$(/bin/date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "\$1" +%s) || exit 64
now=\$(/bin/date -u +%s)
[ "\$end" -gt "\$now" ] && [ "\$end" -le \$((now + $MAX_SECONDS)) ] || exit 64
exec "$APP/Contents/MacOS/selfcontrol-cli" --uid $USER_ID start --blocklist "$LIST" --enddate "\$1"
EOF
chown -R root:wheel "$DIR"
chmod -R go-w "$DIR"
chmod 755 "$BLOCK"
chmod 644 "$LIST"
verify_app "$APP"

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
printf '# Installed by tripwire scripts/root-setup.sh.\n%s ALL = (root) NOPASSWD: %s *\n' "$USER_NAME" "$BLOCK" > "$TMP"
visudo -cf "$TMP" >/dev/null || die "the sudo rule failed validation"
install -m 0440 -o root -g wheel "$TMP" "$RULE"
echo "root setup installed. A trip now starts its block with no dialog."
