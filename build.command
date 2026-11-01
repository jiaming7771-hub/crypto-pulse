#!/bin/zsh
set -eu
cd "$(dirname "$0")"
APP="Crypto Pulse Mini.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp assets/CryptoPulse-XuanqingBrightGold.icns "$APP/Contents/Resources/CryptoPulse-XuanqingBrightGold.icns"
clang -fobjc-arc -fmodules -fmodules-cache-path=/tmp/cryptopulse-clang-cache -mmacosx-version-min=13.0 source/main.m -o "$APP/Contents/MacOS/CryptoPulseMini" -framework Cocoa
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CryptoPulseMini</string>
<key>CFBundleIdentifier</key><string>local.bai.cryptopulsemini</string>
<key>CFBundleName</key><string>Crypto Pulse Mini</string>
<key>CFBundleIconFile</key><string>CryptoPulse-XuanqingBrightGold</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.14</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><false/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
"$APP/Contents/MacOS/CryptoPulseMini" --self-test
