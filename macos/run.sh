#!/bin/zsh
# Runs in the foreground (used by launchd): load config, rebuild if needed, start the widget.
set -euo pipefail
DIR="${0:A:h}"
ROOT="${DIR:h}"
BIN="$DIR/.build/burnrate"

set -a; source "$ROOT/config.env"; set +a

if [[ ! -x "$BIN" || "$DIR/Burnrate.swift" -nt "$BIN" ]]; then
  mkdir -p "$DIR/.build"
  /usr/bin/swiftc -O "$DIR/Burnrate.swift" -o "$BIN"
fi

exec "$BIN"
