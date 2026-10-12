#!/bin/zsh
# Removes the LaunchAgent and stops burnrate.
set -euo pipefail
LABEL="com.github.sven-haude.burnrate"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
pkill -x burnrate 2>/dev/null || true
echo "Autostart removed."
