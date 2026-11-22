#!/bin/bash
set -euo pipefail

# Compile LaunchAtLogin's pinned Swift source into XSnooze itself. An ad-hoc
# signed hardened process cannot load the third-party dynamic framework;
# retain the existing legacy login item without weakening library validation.
resources="${PROJECT_DIR}/Carthage/Build/Mac/LaunchAtLogin.framework/Resources"
source_app="${resources}/LaunchAtLoginHelper.app"
destination="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Library/LoginItems/LaunchAtLoginHelper.app"

mkdir -p "$(dirname "$destination")"
/usr/bin/ditto "$source_app" "$destination"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${PRODUCT_BUNDLE_IDENTIFIER}-LaunchAtLoginHelper" "$destination/Contents/Info.plist"

if [[ "${CODE_SIGNING_ALLOWED:-YES}" != NO && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  /usr/bin/codesign --force --options runtime --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
    --entitlements "${resources}/LaunchAtLogin.entitlements" "$destination"
fi
