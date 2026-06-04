#!/bin/sh
set -eu

echo "Resetting macOS Background Task Management approvals..."
echo "This affects all background items on this Mac, not only Zscaler Split Tunnel."

/usr/bin/sfltool resetbtm

echo
echo "Background Task Management reset complete."
echo "Open Zscaler Split Tunnel, then enable it in System Settings if macOS asks."

if /usr/bin/open "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"; then
  echo "Opened Login Items settings."
else
  echo "Could not open Login Items settings automatically."
fi
