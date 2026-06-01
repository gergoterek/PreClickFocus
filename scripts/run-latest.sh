#!/usr/bin/env bash
# run-latest.sh — build, relaunch, and report on the latest PreClickFocus build.
# No sudo. Does not touch TCC / Accessibility permissions.
set -euo pipefail

PROJECT_DIR="/Users/gergoterek/Movies/OBS/Claude/PreClickFocus"
APP="$PROJECT_DIR/PreClickFocus.app"

cd "$PROJECT_DIR"

# Build the latest .app bundle.
make app

# Stop any running instances (ignore "no process" exit code).
pkill -x PreClickFocus || true

# Launch the freshly built bundle.
open "$APP"

sleep 1

# Show the running process(es).
echo "----- PreClickFocus processes -----"
pgrep -lf PreClickFocus || echo "(none running)"

echo
echo "If Accessibility permission was reset, open System Settings → Privacy & Security → Accessibility and toggle PreClickFocus off/on."
