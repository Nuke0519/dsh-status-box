#!/bin/sh
# Build and install the menu-bar companion for the current user, then register
# it as a login item through launchd (no admin rights needed).
#
# The companion is installed as a real .app bundle (LSUIElement, no Dock icon):
# macOS only routes global hot keys to processes that live inside an application
# bundle, so a bare executable does not receive them.
set -eu
cd "$(dirname "$0")"
PREFIX="$HOME/Library/Application Support/DSHStatusBox"
APP="$PREFIX/DSHStatusBox.app"
MACOS="$APP/Contents/MacOS"
PLIST="$HOME/Library/LaunchAgents/com.dsh.statusbox.menubar.plist"
LABEL="com.dsh.statusbox.menubar"

./build.sh

mkdir -p "$MACOS" "$APP/Contents/Resources"
cp dshstatusbox "$MACOS/dshstatusbox"
chmod +x "$MACOS/dshstatusbox"
cp whale.png "$APP/Contents/Resources/whale.png"

cat > "$APP/Contents/Info.plist" <<INFOEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>状态盒</string>
  <key>CFBundleDisplayName</key><string>状态盒</string>
  <key>CFBundleExecutable</key><string>dshstatusbox</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.3.0</string>
  <key>CFBundleVersion</key><string>1.3.0</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
INFOEOF

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -f "$APP" || true
fi

cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$MACOS/dshstatusbox</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>StandardErrorPath</key><string>$PREFIX/companion.log</string>
  <key>StandardOutPath</key><string>$PREFIX/companion.log</string>
</dict>
</plist>
PLISTEOF

launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
# bootout is asynchronous: wait until the job is really gone before re-adding it
i=0
while launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -gt 40 ] && break
  sleep 0.25
done
if ! launchctl bootstrap "gui/$(id -u)" "$PLIST"; then
  sleep 1
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
fi
launchctl kickstart -k "gui/$(id -u)/$LABEL"
echo "installed: $APP"
echo "login item: $PLIST"
echo "menu bar item and hotkey (option+command+shift+D) are live now"
