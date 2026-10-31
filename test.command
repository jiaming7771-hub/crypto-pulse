#!/bin/zsh
set -eu
cd "$(dirname "$0")"
mkdir -p .build
clang -fobjc-arc -fmodules -fmodules-cache-path=/tmp/cryptopulse-clang-cache -mmacosx-version-min=13.0 tests/reconnect.m -o .build/test-reconnect -framework Cocoa
.build/test-reconnect
if [[ "${1:-}" == "--live" ]]; then
    clang -fobjc-arc -fmodules -fmodules-cache-path=/tmp/cryptopulse-clang-cache -mmacosx-version-min=13.0 tests/live.m -o .build/test-live -framework Cocoa
    .build/test-live
fi
if [[ "${1:-}" == "--windows" ]]; then
    TEST_APP=".build/WindowTests.app"
    mkdir -p "$TEST_APP/Contents/MacOS"
    cat > "$TEST_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>WindowTests</string>
<key>CFBundleIdentifier</key><string>local.bai.cryptopulsemini.window-tests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleName</key><string>Crypto Pulse Window Tests</string>
</dict></plist>
PLIST
    clang -fobjc-arc -fmodules -fmodules-cache-path=/tmp/cryptopulse-clang-cache -mmacosx-version-min=13.0 tests/windows.m -o "$TEST_APP/Contents/MacOS/WindowTests" -framework Cocoa
    "$TEST_APP/Contents/MacOS/WindowTests"
fi
