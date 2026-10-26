#!/bin/bash
# Builds "Jenkins Watch.app", the notifier that posts the build banners with the Jenkins face as its icon.
set -euo pipefail

source_dir=$(cd "$(dirname "$0")" && pwd)
app="$source_dir/Jenkins Watch.app"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
swiftc -O -swift-version 5 -o "$app/Contents/MacOS/jenkins-notifier" "$source_dir/main.swift"
mkdir "$work/Jenkins.iconset"
for size in 16 32 128 256 512; do
	sips -z $size $size "$source_dir/../icons/happy.png" --out "$work/Jenkins.iconset/icon_${size}x${size}.png" >/dev/null
	sips -z $((size * 2)) $((size * 2)) "$source_dir/../icons/happy.png" --out "$work/Jenkins.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$work/Jenkins.iconset" -o "$app/Contents/Resources/Jenkins.icns"
cat >"$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>local.jenkins-menubar.notifier</string>
	<key>CFBundleName</key><string>Jenkins</string>
	<key>CFBundleDisplayName</key><string>Jenkins</string>
	<key>CFBundleExecutable</key><string>jenkins-notifier</string>
	<key>CFBundleIconFile</key><string>Jenkins</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$app" 2>/dev/null
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
echo "built $app"
