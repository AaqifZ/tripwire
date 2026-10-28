#!/bin/sh
# Install the candidate, then observe real input without a diagnostic block.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
"$SCRIPT_DIR/install.sh"
"$HOME/.local/bin/tripwire" --version
"$HOME/.local/bin/tripwire" status
cat <<'EOF'

Local hover check (30 seconds):
1. Keep X visible beside Slack.
2. Give Slack focus, then scroll X without a click.
3. Check for site=x.com, source=hover, and nonzero scrolls.
4. Type only in Slack. Those keys must not receive credit on X.

The probe starts no block and changes no display filter.
The installed daemon remains in real mode.
EOF
"$HOME/.local/bin/tripwire" probe 30
