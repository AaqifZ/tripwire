#!/bin/sh
# Build tripwire and run it as a LaunchAgent.
# Usage: scripts/install.sh          real mode (5 min window, 90 min block)
#        scripts/install.sh --test   test mode (30 s window, no block)
set -e
cd "$(dirname "$0")/.."

LABEL=com.aaqifz.tripwire
BIN="$HOME/.local/bin/tripwire"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
MODE_ARG=""
[ "$1" = "--test" ] && MODE_ARG="<string>--test</string>"

swift build -c release
mkdir -p "$HOME/.local/bin" "$HOME/.tripwire"
# Keep the same path on each install: macOS grants permissions per binary path.
cp .build/release/tripwire "$BIN"
# A fixed certificate keeps the Input Monitoring grant across rebuilds (see make-signing-cert.sh).
# The first install creates it. If that fails, fall back to an ad-hoc signature.
security find-identity -p codesigning | grep -q tripwire-local || scripts/make-signing-cert.sh || true
if security find-identity -p codesigning | grep -q tripwire-local; then
  codesign --force --sign tripwire-local --identifier "$LABEL" "$BIN"
else
  echo "warning: no tripwire-local certificate (scripts/make-signing-cert.sh failed). Each rebuild will need Input Monitoring again."
  codesign --force --sign - --identifier "$LABEL" "$BIN"
fi

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN</string><string>run</string>$MODE_ARG</array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardErrorPath</key><string>$HOME/.tripwire/tripwire.err</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# bootout returns before the old service is gone. Wait, or bootstrap fails with error 5.
i=0
while launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 && [ $i -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
launchctl bootstrap "gui/$(id -u)" "$PLIST"
[ -x /Applications/SelfControl.app/Contents/MacOS/selfcontrol-cli ] || echo "warning: SelfControl is not in /Applications. Tripwire cannot block until you install it."
echo "tripwire installed${MODE_ARG:+ (test mode)}. Log: ~/.tripwire/tripwire.err"
