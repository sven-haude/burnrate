#!/bin/zsh
# macOS: double-click in Finder (or run ./start.command) to (re)start burnrate.
set -euo pipefail
DIR="${0:A:h}"
LABEL="com.github.sven-haude.burnrate"

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Swift compiler missing – install it with: xcode-select --install"
  exit 1
fi

if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  launchctl kickstart -k "gui/$(id -u)/$LABEL"
else
  pkill -x burnrate 2>/dev/null || true
  nohup "$DIR/macos/run.sh" >/dev/null 2>"$DIR/macos/burnrate.log" &
  disown
fi
echo "burnrate is running (right-click the widget → Quit)."
