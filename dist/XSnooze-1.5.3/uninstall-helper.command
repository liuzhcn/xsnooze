#!/bin/bash
set -euo pipefail

HELPER_LABEL="com.liuzhcn.XSnooze.Helper"
HELPER_DEST="/Library/PrivilegedHelperTools/${HELPER_LABEL}"
PLIST_DEST="/Library/LaunchDaemons/${HELPER_LABEL}.plist"
STATE_DEST="/Library/PrivilegedHelperTools/${HELPER_LABEL}.state.plist"

echo "Uninstalling XSnooze privileged helper..."
echo "Administrator password may be required."

if sudo launchctl print "system/${HELPER_LABEL}" >/dev/null 2>&1; then
  sudo launchctl bootout system "${PLIST_DEST}" || true
fi

sudo rm -f "${PLIST_DEST}"
sudo rm -f "${HELPER_DEST}"
sudo rm -f "${STATE_DEST}"

echo "XSnooze privileged helper uninstalled."

