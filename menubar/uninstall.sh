#!/bin/sh
# Remove the menu-bar companion and its login item.
set -eu
PREFIX="$HOME/Library/Application Support/DSHStatusBox"
PLIST="$HOME/Library/LaunchAgents/com.dsh.statusbox.menubar.plist"
LABEL="com.dsh.statusbox.menubar"

launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
rm -f "$PLIST"
rm -rf "$PREFIX"
echo "removed $LABEL"
