#!/bin/bash
set -euo pipefail

PROJECT_DIR="/Users/gergoterek/Movies/OBS/Claude/PreClickFocus"
APP_PATH="${PROJECT_DIR}/PreClickFocus.app"
DIST_DIR="${PROJECT_DIR}/dist"
STAGING_DIR="${PROJECT_DIR}/.dmg-staging"
APP_NAME="PreClickFocus"
TIMESTAMP="$(/bin/date +%Y%m%d-%H%M%S)"
DMG_PATH="${DIST_DIR}/${APP_NAME}-${TIMESTAMP}.dmg"

if [ ! -d "$APP_PATH" ]; then
  echo "ERROR: App not found:"
  echo "$APP_PATH"
  exit 1
fi

/bin/rm -rf "$STAGING_DIR"
/bin/mkdir -p "$STAGING_DIR"
/bin/mkdir -p "$DIST_DIR"

/bin/cp -R "$APP_PATH" "$STAGING_DIR/"
/bin/ln -s /Applications "$STAGING_DIR/Applications"

/usr/bin/hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

/bin/rm -rf "$STAGING_DIR"

echo ""
echo "DMG created:"
echo "$DMG_PATH"
