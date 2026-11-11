#!/usr/bin/env bash
# One-command verification for both companions (no network, no secrets).
#
#   ./scripts/verify.sh          # 能跑什么就跑什么，缺工具自动跳过
#   ./scripts/verify.sh --full   # 缺工具视为失败（CI 用）
#
# Layers:
#   1. plugin client: node --check + pure function tests
#   2. offline render harness (if /tmp/qd-test exists: DOM-level checks)
#   3. bridge protocol: dotnet run on windows/tests/BridgeSmoke (any OS)
#   4. macOS companion: clang compile of menubar/main.m (macOS only)
#   5. Windows companion: dotnet build of the WinForms app (needs EnableWindowsTargeting)
set -u

FULL=0
[ "${1:-}" = "--full" ] && FULL=1
cd "$(dirname "$0")/.." || exit 1

# local dev convenience: a private .NET install is picked up when not on PATH
if ! command -v dotnet >/dev/null 2>&1 && [ -x "$HOME/.dotnet-winbuild/dotnet" ]; then
  export DOTNET_ROOT="$HOME/.dotnet-winbuild"
  export PATH="$DOTNET_ROOT:$PATH"
fi

fail=0
note() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; fail=1; }
skip() { printf '\033[1;33mSKIP\033[0m %s\n' "$*"; [ "$FULL" = "1" ] && fail=1; }

note "1/5 plugin client"
if command -v node >/dev/null 2>&1; then
  node --check client.js && ok "client.js syntax" || bad "client.js syntax"
  node --test tests/*.cjs >/dev/null 2>&1 && ok "pure function tests" || bad "pure function tests"
else
  skip "node not installed"
fi

note "2/5 offline render harness"
if [ -f /tmp/qd-test/test.js ]; then
  (cd /tmp/qd-test && node test.js 2>&1 | tail -2)
else
  skip "harness not present at /tmp/qd-test (dev-only fixture)"
fi

note "3/5 bridge protocol (dotnet)"
if command -v dotnet >/dev/null 2>&1; then
  dotnet run --project windows/tests/BridgeSmoke -c Release 2>&1 | tail -2
  [ "${PIPESTATUS[0]}" = "0" ] && ok "bridge smoke" || bad "bridge smoke"
else
  skip "dotnet not installed"
fi

note "4/5 macOS companion"
if [ "$(uname -s)" = "Darwin" ] && command -v clang >/dev/null 2>&1; then
  clang -fobjc-arc -fmodules -framework Cocoa -framework Carbon -framework ImageIO \
    -O2 -o /tmp/dsb-verify-menubar menubar/main.m 2>/dev/null \
    && ok "menubar/main.m compiles" || bad "menubar/main.m compiles"
else
  skip "not macOS / no clang"
fi

note "5/5 Windows companion"
if command -v dotnet >/dev/null 2>&1 && [ -d windows/src/DSHStatusBox.App ]; then
  dotnet build windows/src/DSHStatusBox.App -c Release -v q --nologo 2>&1 | tail -3
  [ "${PIPESTATUS[0]}" = "0" ] && ok "WinForms app builds" || bad "WinForms app builds"
else
  skip "dotnet not installed"
fi

note "result"
if [ "$fail" = "0" ]; then
  printf '\033[1;32mALL CHECKS PASSED\033[0m\n'
else
  printf '\033[1;31mSOME CHECKS FAILED\033[0m\n'
fi
exit "$fail"
