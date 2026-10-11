#!/bin/sh
# Stop tripwire and remove the LaunchAgent and binary. Keeps ~/.tripwire (the event log).
# A running SelfControl block is not affected.
LABEL=com.aaqifz.tripwire
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$HOME/.local/bin/tripwire"
echo "tripwire removed. Event log kept in ~/.tripwire/"
