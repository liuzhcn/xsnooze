#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DERIVED_DATA="${PROJECT_DIR}/build/DerivedData"
VERSION="${1:-}"

cd "${PROJECT_DIR}"

if [[ -z "${VERSION}" ]]; then
  VERSION="$(xcodebuild -project Bluesnooze.xcodeproj -scheme Bluesnooze -showBuildSettings 2>/dev/null | awk -F '= ' '/MARKETING_VERSION/ { print $2; exit }')"
fi

if [[ -z "${VERSION}" ]]; then
  echo "Unable to determine MARKETING_VERSION."
  exit 1
fi

APP_SOURCE="${DERIVED_DATA}/Build/Products/Release/XSnooze.app"
DIST_DIR="${PROJECT_DIR}/dist"
DMG_ROOT="${DIST_DIR}/XSnooze-${VERSION}"
DMG_PATH="${DIST_DIR}/XSnooze-${VERSION}.dmg"

xcodebuild \
  -project Bluesnooze.xcodeproj \
  -scheme Bluesnooze \
  -configuration Release \
  -derivedDataPath "${DERIVED_DATA}" \
  CODE_SIGNING_ALLOWED=NO \
  build

rm -rf "${DMG_ROOT}" "${DMG_PATH}"
mkdir -p "${DMG_ROOT}"

ditto "${APP_SOURCE}" "${DMG_ROOT}/XSnooze.app"
ln -s /Applications "${DMG_ROOT}/Applications"
ditto "${SCRIPT_DIR}/install-helper.command" "${DMG_ROOT}/install-helper.command"
ditto "${SCRIPT_DIR}/uninstall-helper.command" "${DMG_ROOT}/uninstall-helper.command"

hdiutil create \
  -volname XSnooze \
  -srcfolder "${DMG_ROOT}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${DMG_ROOT}/XSnooze.app/Contents/Info.plist"
ls -lh "${DMG_PATH}"
