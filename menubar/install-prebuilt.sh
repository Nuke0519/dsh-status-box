#!/bin/bash
# Install the macOS menu-bar companion WITHOUT Xcode command line tools.
#
# The compiled universal binary (arm64 + x86_64) ships as a GitHub release
# asset, so this script only downloads, copies, signs ad-hoc and registers the
# LaunchAgent — no clang, no build step.
#
# Usage:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Nuke0519/dsh-status-box/main/menubar/install-prebuilt.sh)"
#
# Uninstall:  bash -c "$(curl -fsSL https://raw.githubusercontent.com/Nuke0519/dsh-status-box/main/menubar/uninstall.sh)"

set -euo pipefail

LABEL="com.dsh.statusbox.menubar"
PREFIX="$HOME/Library/Application Support/DSHStatusBox"
APP="$PREFIX/DSHStatusBox.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
ASSET_URL="${DSH_STATUS_BOX_ASSET_URL:-https://github.com/Nuke0519/dsh-status-box/releases/latest/download/DSHStatusBox-menubar-macos-universal.zip}"

say() { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

if [ "$(uname -s)" != "Darwin" ]; then
  fail "This companion is macOS only."
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say "Downloading the prebuilt companion…"
if ! curl -fsSL "$ASSET_URL" -o "$TMP/companion.zip"; then
  fail "Download failed. Check your network, or build from source with menubar/install.sh"
fi

unzip -q "$TMP/companion.zip" -d "$TMP/companion"
BIN="$TMP/companion/dshstatusbox"
[ -f "$BIN" ] || fail "The release asset did not contain dshstatusbox"

say "Installing into $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$PREFIX" "$HOME/Library/LaunchAgents"
cp "$BIN" "$APP/Contents/MacOS/dshstatusbox"
chmod +x "$APP/Contents/MacOS/dshstatusbox"
if [ -f "$TMP/companion/whale.png" ]; then
  cp "$TMP/companion/whale.png" "$APP/Contents/Resources/whale.png"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleExecutable</key><string>dshstatusbox</string>
  <key>CFBundleIdentifier</key><string>com.dsh.statusbox.menubar</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>状态盒</string>
  <key>CFBundleDisplayName</key><string>状态盒</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.3.0</string>
  <key>CFBundleVersion</key><string>1.3.0</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: keeps Gatekeeper happy and lets macOS deliver the Carbon
# global hotkey (it only routes hot keys to processes that live in an app).
codesign --force --sign - --deep "$APP" >/dev/null 2>&1 || true

say "Registering the login item"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP/Contents/MacOS/dshstatusbox</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key><false/>
  </dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>StandardOutPath</key><string>$PREFIX/companion.log</string>
  <key>StandardErrorPath</key><string>$PREFIX/companion.log</string>
</dict>
</plist>
PLIST

DOMAIN="gui/$(id -u)"
launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
for _ in $(seq 1 40); do
  launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
  sleep 0.25
done
launchctl bootstrap "$DOMAIN" "$AGENT" 2>/dev/null || { sleep 0.8; launchctl bootstrap "$DOMAIN" "$AGENT"; }
launchctl kickstart -k "$DOMAIN/$LABEL" >/dev/null 2>&1 || true

for _ in $(seq 1 40); do
  if curl -fsS --max-time 0.5 "http://127.0.0.1:59421/ping" >/dev/null 2>&1; then
    say "Done. The whale now lives in your menu bar (⌥⌘⇧D opens the capture window)."
    exit 0
  fi
  sleep 0.25
done

say "Installed, but the companion is not answering on 127.0.0.1:59421 yet."
say "Check $PREFIX/companion.log, or log out and back in."
