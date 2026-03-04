#!/usr/bin/env bash
set -e

rm -rf autoSnip.app autoSnip_bin

swiftc \
    -framework Cocoa \
    -framework ScreenCaptureKit \
    -framework Carbon \
    -framework Vision \
    -target arm64-apple-macos14.0 \
    -swift-version 5 \
    Sources/main.swift -o autoSnip_bin

mkdir -p autoSnip.app/Contents/MacOS
cp autoSnip_bin autoSnip.app/Contents/MacOS/autoSnip
cp Info.plist autoSnip.app/Contents/Info.plist

codesign --deep --force --sign "autoSnip Developer" \
    --entitlements autoSnip.entitlements \
    --options runtime \
    autoSnip.app

echo "Build complete: autoSnip.app"
echo "Run with: open autoSnip.app"
