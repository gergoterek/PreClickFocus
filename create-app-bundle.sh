#!/usr/bin/env bash
# create-app-bundle.sh
# Creates the PreClickFocus.app directory structure and copies Info.plist.
# Idempotent — safe to run multiple times.
# Does NOT copy the binary; that is handled by: make app
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE="$SCRIPT_DIR/PreClickFocus.app"

mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources"

cp "$SCRIPT_DIR/Info.plist" "$BUNDLE/Contents/Info.plist"

echo "PreClickFocus.app structure ready:"
echo "  $BUNDLE/Contents/Info.plist"
echo "  $BUNDLE/Contents/MacOS/   (binary goes here via: make app)"
echo "  $BUNDLE/Contents/Resources/"
