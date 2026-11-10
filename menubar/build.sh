#!/bin/sh
# Build the macOS menu-bar companion. Requires the Xcode command line tools.
set -eu
cd "$(dirname "$0")"
clang -fobjc-arc -fmodules -framework Cocoa -framework Carbon -framework ImageIO -O2 -o dshstatusbox main.m
echo "built $(pwd)/dshstatusbox"
