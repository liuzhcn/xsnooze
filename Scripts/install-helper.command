#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

HELPER_LABEL="com.liuzhcn.XSnooze.Helper"
HELPER_DEST="/Library/PrivilegedHelperTools/${HELPER_LABEL}"
PLIST_DEST="/Library/LaunchDaemons/${HELPER_LABEL}.plist"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="/Applications/XSnooze.app"

HELPER_SOURCE="${APP_PATH}/Contents/Library/LaunchServices/${HELPER_LABEL}"

if [[ ! -x "${HELPER_SOURCE}" ]]; then
  echo "XSnooze helper not found at:"
  echo "  ${HELPER_SOURCE}"
  echo
  echo "Drag XSnooze.app into Applications first."
  exit 1
fi

app_hash() {
  /usr/bin/codesign -d --verbose=4 "$1" 2>&1 | /usr/bin/awk -F= '/^CDHash=/ { print $2 }'
}

# Only authorize the exact, intact hardened app the user installed. A bundle
# identifier by itself is not a trusted identity for an ad-hoc signed app.
/usr/bin/codesign --verify --deep --strict -R='identifier "com.liuzhcn.XSnooze"' "${APP_PATH}"
/usr/bin/codesign --verify --strict -R='identifier "com.liuzhcn.XSnooze.Helper"' "${HELPER_SOURCE}"
for signed_path in "${APP_PATH}" "${HELPER_SOURCE}"; do
  if ! /usr/bin/codesign -d --verbose=4 "${signed_path}" 2>&1 | /usr/bin/grep -E '^CodeDirectory .*flags=.*\([^)]*runtime' >/dev/null; then
    echo "XSnooze and its Helper must have hardened runtime signatures. Use the packaged release build."
    exit 1
  fi
  # Do not authorize a development build that relaxes code injection or debugging protections.
  ENTITLEMENTS="$(/usr/bin/codesign -d --entitlements :- "${signed_path}" 2>/dev/null)"
  if /usr/bin/grep -Eq 'com\.apple\.security\.(get-task-allow|cs\.)' <<< "${ENTITLEMENTS}"; then
    echo "XSnooze has development or runtime exception entitlements. Use the packaged release build."
    exit 1
  fi
done

BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${APP_PATH}/Contents/Info.plist")"
if [[ ! "${BUILD_NUMBER}" =~ ^[0-9]+$ ]] || [[ "${BUILD_NUMBER}" -lt 2 ]]; then
  echo "Install XSnooze 1.7.9 or later first. Older versions do not support authenticated Helper connections."
  exit 1
fi

CLIENT_HASH="$(app_hash "${APP_PATH}")"
if [[ ! "${CLIENT_HASH}" =~ ^[[:xdigit:]]{40}$ ]]; then
  echo "Could not determine the app's signing identity."
  exit 1
fi

if [[ -d "${SCRIPT_DIR}/XSnooze.app" ]]; then
  /usr/bin/codesign --verify --deep --strict "${SCRIPT_DIR}/XSnooze.app"
  if [[ "$(app_hash "${SCRIPT_DIR}/XSnooze.app")" != "${CLIENT_HASH}" ]]; then
    echo "The installed XSnooze.app does not match this installer. Replace it with the app from this package first."
    exit 1
  fi
  # Prefer the matching Helper in the original read-only DMG when available.
  PACKAGED_HELPER="${SCRIPT_DIR}/XSnooze.app/Contents/Library/LaunchServices/${HELPER_LABEL}"
  if ! /usr/bin/cmp -s "${HELPER_SOURCE}" "${PACKAGED_HELPER}"; then
    echo "The installed Helper does not match this package. Replace XSnooze.app first."
    exit 1
  fi
  HELPER_SOURCE="${PACKAGED_HELPER}"
fi

HELPER_HASH="$(app_hash "${HELPER_SOURCE}")"
if [[ ! "${HELPER_HASH}" =~ ^[[:xdigit:]]{40}$ ]]; then
  echo "Could not determine the Helper's signing identity."
  exit 1
fi

echo "Installing XSnooze privileged helper..."
echo "Administrator password may be required."

TEMP_PLIST="$(mktemp "/tmp/${HELPER_LABEL}.plist.XXXXXX")"
trap 'rm -f "${TEMP_PLIST}"' EXIT

if sudo launchctl print "system/${HELPER_LABEL}" >/dev/null 2>&1; then
  echo "Stopping existing XSnooze privileged helper..."
  sudo launchctl bootout "system/${HELPER_LABEL}"
fi

sudo mkdir -p /Library/PrivilegedHelperTools
sudo install -o root -g wheel -m 755 "${HELPER_SOURCE}" "${HELPER_DEST}"
/usr/bin/codesign --verify --strict -R="identifier \"${HELPER_LABEL}\" and cdhash H\"${HELPER_HASH}\"" "${HELPER_DEST}"

cat > "${TEMP_PLIST}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${HELPER_LABEL}</string>
	<key>MachServices</key>
	<dict>
		<key>${HELPER_LABEL}</key>
		<true/>
	</dict>
	<key>ProgramArguments</key>
	<array>
		<string>${HELPER_DEST}</string>
		<string>--client-cdhash</string>
		<string>${CLIENT_HASH}</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
</dict>
</plist>
PLIST

sudo install -o root -g wheel -m 644 "${TEMP_PLIST}" "${PLIST_DEST}"

sudo launchctl enable "system/${HELPER_LABEL}"
sudo launchctl bootstrap system "${PLIST_DEST}"

echo "XSnooze privileged helper installed."
echo "You can now run XSnooze.app."
