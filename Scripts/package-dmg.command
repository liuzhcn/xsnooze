#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERSION="${1:-}"

cd "${PROJECT_DIR}"

if [[ -z "${VERSION}" ]]; then
  VERSION="$(xcodebuild -project Bluesnooze.xcodeproj -scheme Bluesnooze -showBuildSettings 2>/dev/null | awk -F '= ' '/MARKETING_VERSION/ && !found { print $2; found=1 }')"
fi

if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Unable to determine MARKETING_VERSION."
  exit 1
fi

DIST_DIR="${PROJECT_DIR}/dist"
DMG_ROOT="${DIST_DIR}/XSnooze-${VERSION}"
DMG_PATH="${DIST_DIR}/XSnooze-${VERSION}.dmg"
ZIP_PATH="${DIST_DIR}/XSnooze-${VERSION}.zip"

if [[ -e "${DMG_ROOT}" || -e "${DMG_PATH}" || -e "${ZIP_PATH}" ]]; then
  echo "Release ${VERSION} already exists; use a new version."
  exit 1
fi

# Use fresh build output so previously embedded dynamic frameworks cannot
# survive an incremental build. The installer pins the final signed app.
mkdir -p "${PROJECT_DIR}/build"
DERIVED_DATA="$(mktemp -d "${PROJECT_DIR}/build/Release.XXXXXX")"
APP_SOURCE="${DERIVED_DATA}/Build/Products/Release/XSnooze.app"

xcodebuild \
  -project Bluesnooze.xcodeproj \
  -scheme Bluesnooze \
  -configuration Release \
  -derivedDataPath "${DERIVED_DATA}" \
  CODE_SIGNING_ALLOWED=NO \
  build

ACTUAL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_SOURCE}/Contents/Info.plist")"
if [[ "${ACTUAL_VERSION}" != "${VERSION}" ]]; then
  echo "Package version does not match the built app (${ACTUAL_VERSION})."
  exit 1
fi

# Sign every nested executable, then the outer app, with hardened runtime.
# Local ad-hoc signatures do not require a Developer ID certificate.
/usr/bin/codesign --force --options runtime --sign - \
  "${APP_SOURCE}/Contents/Library/LaunchServices/com.liuzhcn.XSnooze.Helper"
/usr/bin/codesign --force --options runtime --sign - \
  --entitlements "${PROJECT_DIR}/Carthage/Build/Mac/LaunchAtLogin.framework/Resources/LaunchAtLogin.entitlements" \
  "${APP_SOURCE}/Contents/Library/LoginItems/LaunchAtLoginHelper.app"
/usr/bin/codesign --force --options runtime --sign - \
  --entitlements "${PROJECT_DIR}/Bluesnooze/Bluesnooze.entitlements" "${APP_SOURCE}"
/usr/bin/codesign --verify --deep --strict "${APP_SOURCE}"

mkdir -p "${DMG_ROOT}"

ditto "${APP_SOURCE}" "${DMG_ROOT}/XSnooze.app"
ln -s /Applications "${DMG_ROOT}/Applications"
ditto "${SCRIPT_DIR}/install-helper.command" "${DMG_ROOT}/install-helper.command"
ditto "${SCRIPT_DIR}/uninstall-helper.command" "${DMG_ROOT}/uninstall-helper.command"

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "${DMG_ROOT}" "${ZIP_PATH}"

hdiutil create \
  -volname XSnooze \
  -srcfolder "${DMG_ROOT}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${DMG_ROOT}/XSnooze.app/Contents/Info.plist"
ls -lh "${DMG_PATH}" "${ZIP_PATH}"
