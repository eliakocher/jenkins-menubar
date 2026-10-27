#!/bin/bash
# Builds "Jenkins Watch.app": the notifier that posts the build banners with the Jenkins butler as its icon, and the
# settings window.
set -euo pipefail

source_dir=$(cd "$(dirname "$0")" && pwd)
# Since the macOS 27 SDK, @State is SwiftUI's State macro, whose plugin only Xcode has: the views use @ViewState, the
# property wrapper under another name (see ViewState.swift), so the app builds with only the Command Line Tools too.
if grep -nE '^[^/]*@(SwiftUI(Core)?\.)?State\b' "$source_dir"/*.swift >&2; then
	echo 'Use @ViewState instead of @State, so the app builds without Xcode too (see ViewState.swift).' >&2
	exit 1
fi
app="$source_dir/Jenkins Watch.app"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
swiftc -O -swift-version 5 -o "$app/Contents/MacOS/jenkins-notifier" "$source_dir"/*.swift
# With Xcode, the layered Icon Composer icon, which macOS 26 draws in Liquid Glass and in the dark, clear and tinted
# styles (plus a flat AppIcon.icns for older macOS); with only the Command Line Tools, the flat icon.
if ! xcrun actool "$source_dir/../icons/AppIcon.icon" --compile "$app/Contents/Resources" --platform macosx \
	--minimum-deployment-target 14.0 --app-icon AppIcon --output-partial-info-plist "$work/icon.plist" >/dev/null 2>&1; then
	mkdir "$work/AppIcon.iconset"
	for size in 16 32 128 256 512; do
		sips -z $size $size "$source_dir/../icons/app.png" --out "$work/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
		sips -z $((size * 2)) $((size * 2)) "$source_dir/../icons/app.png" --out "$work/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
	done
	iconutil -c icns "$work/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
fi
cat >"$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>local.jenkins-menubar.notifier</string>
	<key>CFBundleName</key><string>Jenkins</string>
	<key>CFBundleDisplayName</key><string>Jenkins</string>
	<key>CFBundleExecutable</key><string>jenkins-notifier</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSUIElement</key><true/>
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key><string>local.jenkins-menubar.settings</string>
			<key>CFBundleURLSchemes</key><array><string>jenkins-menubar</string></array>
		</dict>
	</array>
</dict>
</plist>
PLIST
if [[ -f $app/Contents/Resources/Assets.car ]]; then
	plutil -insert CFBundleIconName -string AppIcon "$app/Contents/Info.plist"
fi
codesign --force --sign - "$app" 2>/dev/null
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
echo "built $app"
