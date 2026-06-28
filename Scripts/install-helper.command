#!/bin/bash
set -euo pipefail

HELPER_LABEL="com.liuzhcn.XSnooze.Helper"
HELPER_DEST="/Library/PrivilegedHelperTools/${HELPER_LABEL}"
PLIST_DEST="/Library/LaunchDaemons/${HELPER_LABEL}.plist"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="${SCRIPT_DIR}/XSnooze.app"

if [[ ! -d "${APP_PATH}" ]]; then
  APP_PATH="/Applications/XSnooze.app"
fi

HELPER_SOURCE="${APP_PATH}/Contents/Library/LaunchServices/${HELPER_LABEL}"

if [[ ! -x "${HELPER_SOURCE}" ]]; then
  echo "XSnooze helper not found at:"
  echo "  ${HELPER_SOURCE}"
  echo
  echo "Put install-helper.command next to XSnooze.app, or install XSnooze.app in /Applications first."
  exit 1
fi

echo "Installing XSnooze privileged helper..."
echo "Administrator password may be required."

if sudo launchctl print "system/${HELPER_LABEL}" >/dev/null 2>&1; then
  echo "Stopping existing XSnooze privileged helper..."
  sudo launchctl bootout system "${PLIST_DEST}" || true
fi

sudo mkdir -p /Library/PrivilegedHelperTools
sudo cp "${HELPER_SOURCE}" "${HELPER_DEST}"
sudo chown root:wheel "${HELPER_DEST}"
sudo chmod 755 "${HELPER_DEST}"

TEMP_PLIST="$(mktemp "/tmp/${HELPER_LABEL}.plist.XXXXXX")"
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
	</array>
	<key>RunAtLoad</key>
	<true/>
</dict>
</plist>
PLIST

sudo cp "${TEMP_PLIST}" "${PLIST_DEST}"
rm -f "${TEMP_PLIST}"
sudo chown root:wheel "${PLIST_DEST}"
sudo chmod 644 "${PLIST_DEST}"

sudo launchctl bootstrap system "${PLIST_DEST}"
sudo launchctl enable "system/${HELPER_LABEL}"

echo "XSnooze privileged helper installed."
echo "You can now run XSnooze.app."
