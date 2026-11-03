#!/bin/bash
# Builds build/app.noindex/MegaMonitor.app with only the Command Line Tools (or with Xcode, if it is the active developer
# directory).
#
#   ./build.sh [--debug] [--install]
#
#   --debug    a debug build, which has the design gallery (MegaMonitor --gallery)
#   --install  also copies the app to ~/Applications/MegaMonitor.app and registers it there; an old
#              ~/Applications/menubar-monitor.app is removed first, and open at login carried over from the former
#              identity (scripts/migrate-old-bundle.sh)
set -euo pipefail

root=$(cd "$(dirname "$0")" && pwd)
config=release
install=false
for arg in "$@"; do
	case $arg in
	--debug) config=debug ;;
	--install) install=true ;;
	*)
		echo "usage: $0 [--debug] [--install]" >&2
		exit 2
		;;
	esac
done

# Guards. The CLT have no plugins for these macros, so a source that uses one builds only in Xcode: SwiftUI's @State,
# @Entry, @Animatable and @AnimatableIgnored, the previews' #Preview and @Previewable, Foundation's #Predicate,
# #Expression and #bundle. SwiftData (@Model), App Intents, TipKit and Foundation Models are refused as a whole, since
# their APIs are built on macros. Views use @ViewState (Sources/MenubarUI/Support/ViewState.swift). Lines whose match
# comes after a // are comments and pass.
cd "$root"
if grep -rnE --include='*.swift' \
	-e '^[^/]*@(SwiftUI(Core)?\.)?(State|Entry|Animatable|AnimatableIgnored|Previewable)\b' \
	-e '^[^/]*#(Preview|Predicate|Expression|bundle)\b' \
	-e '^[^/]*\bimport +(SwiftData|AppIntents|TipKit|FoundationModels)\b' \
	Sources Tests >&2; then
	echo 'These macros need Xcode; use @ViewState for @State, and plain Swift for the rest.' >&2
	exit 1
fi
if grep -rnE --include='*.swift' \
	-e '^[^/]*\bimport +((typealias|struct|class|enum|protocol|let|var|func) +)?(AppKit|Cocoa|SwiftUI|SwiftUICore|Charts|UIKit)\b' \
	Sources/MenubarCore >&2; then
	echo 'MenubarCore stays free of AppKit and SwiftUI; move this code to MenubarUI or MenubarMonitor.' >&2
	exit 1
fi
# The repository is public: the company's name stays out of every file it commits.
scripts/check-names.sh

# The SwiftPM product is megamonitor; the executable in the bundle is called MegaMonitor.
swift build -c "$config" --product megamonitor
bin=$(swift build -c "$config" --show-bin-path)

# In a folder Spotlight skips (`.noindex`), so search shows only the installed app (the user, 2026-11-03).
app=$root/build/app.noindex/MegaMonitor.app
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The build folder's bundles of the old name leave Launch Services too, so only one app answers to the bundle id.
for stale in "$root/build/menubar-monitor.app" "$root/build/gallery/menubar-monitor.app" \
	"$root/build/MegaMonitor.app" "$root/build/gallery/MegaMonitor.app"; do
	if [[ -d $stale ]]; then
		"$lsregister" -u "$stale" 2>/dev/null || true
		rm -rf "$stale"
	fi
done
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/megamonitor" "$app/Contents/MacOS/MegaMonitor"
cp icons/menubar.png icons/happy.png icons/sad.png icons/gitlab.png "$app/Contents/Resources/"
# The changelog, for What's New (Help menu, and the Inbox's entry after an update); a missing file leaves the view empty.
if [[ -f CHANGELOG.md ]]; then
	cp CHANGELOG.md "$app/Contents/Resources/"
fi
# The easter eggs' art (EGG-02 to EGG-04) is optional: a missing file leaves the plain butler.
for egg in menubar-party menubar-santa menubar-bow-1 menubar-bow-2 happy-party happy-santa sad-santa coffee \
	peek-side peek-bottom peek-top caught happy-halloween sad-halloween happy-carnival sad-carnival happy-easter sad-easter menubar-wink \
	peek-side-party peek-side-santa peek-side-witch inbox-zero; do
	if [[ -f icons/$egg.png ]]; then
		cp "icons/$egg.png" "$app/Contents/Resources/"
	fi
done
# With Xcode, the layered Icon Composer icon, which macOS draws in Liquid Glass and in the dark, clear and tinted
# styles; with only the CLT, which have no actool, a flat icon. A build that pins DEVELOPER_DIR to the CLT still borrows
# the actool of the Xcode that xcode-select names, if there is one: only the icon needs it, the code doesn't.
compile_icon() {
	xcrun actool icons/AppIcon.icon --compile "$app/Contents/Resources" --platform macosx \
		--minimum-deployment-target 26.0 --app-icon AppIcon --output-partial-info-plist "$work/icon.plist" >/dev/null 2>&1
}
if ! compile_icon && ! (unset DEVELOPER_DIR && compile_icon); then
	mkdir "$work/AppIcon.iconset"
	for size in 16 32 128 256 512; do
		sips -z $size $size icons/app.png --out "$work/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
		sips -z $((size * 2)) $((size * 2)) icons/app.png --out "$work/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
	done
	iconutil -c icns "$work/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
fi

# The hash of everything the app is built from, so the app can tell when the checkout has changed since: the SHA-256
# of the `shasum -a 256` listing of Package.swift, build.sh, Sources/ and icons/, without hidden files, sorted by
# path in byte order. SourceHash in MenubarCore computes the same.
source_hash=$(find Package.swift build.sh Sources icons -type f ! -path '*/.*' -print0 | LC_ALL=C sort -z |
	xargs -0 shasum -a 256 | shasum -a 256 | cut -c1-64)

cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<!-- The identity is MegaMonitor since Task 7.12; the app copies the former menubar-monitor preferences, tokens
	     and folders once at its first launch (IdentityMigration). -->
	<key>CFBundleIdentifier</key><string>local.megamonitor</string>
	<key>CFBundleName</key><string>MegaMonitor</string>
	<key>CFBundleDisplayName</key><string>MegaMonitor</string>
	<key>CFBundleExecutable</key><string>MegaMonitor</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0.5</string>
	<key>CFBundleVersion</key><string>6</string>
	<key>LSMinimumSystemVersion</key><string>26.0</string>
	<key>LSUIElement</key><true/>
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<!-- megamonitor://, and the former menubar-monitor:// so links written before the rename still work. -->
			<key>CFBundleURLName</key><string>local.megamonitor</string>
			<key>CFBundleURLSchemes</key><array><string>megamonitor</string><string>menubar-monitor</string></array>
		</dict>
		<!-- http and https, so the app can be the default browser when the user turns on "Open GitLab and Jenkins Links in
		     MegaMonitor" (APP-09). Nothing changes while that setting is off: macOS lists the app as a candidate
		     and sends it no link until it is chosen. -->
		<dict>
			<key>CFBundleURLName</key><string>Web links</string>
			<key>CFBundleTypeRole</key><string>Viewer</string>
			<key>CFBundleURLSchemes</key><array><string>http</string><string>https</string></array>
		</dict>
	</array>
	<!-- What System Settings' list of browsers looks for besides the schemes: a Viewer for HTML. -->
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key><string>HTML document</string>
			<key>CFBundleTypeRole</key><string>Viewer</string>
			<key>LSHandlerRank</key><string>Alternate</string>
			<key>LSItemContentTypes</key><array><string>public.html</string><string>public.xhtml</string></array>
		</dict>
	</array>
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsLocalNetworking</key><true/>
	</dict>
	<key>MMSourceRoot</key><string>$root</string>
	<key>MMSourceHash</key><string>$source_hash</string>
</dict>
</plist>
PLIST
if [[ -f $app/Contents/Resources/Assets.car ]]; then
	plutil -insert CFBundleIconName -string AppIcon "$app/Contents/Info.plist"
fi
plutil -lint -s "$app/Contents/Info.plist"

codesign --force --sign - "$app"
if $install; then
	installed=$HOME/Applications/MegaMonitor.app
	mkdir -p "$HOME/Applications"
	# The app was called menubar-monitor before: take that bundle away, and carry open at login over.
	"$root/scripts/migrate-old-bundle.sh"
	rm -rf "$installed"
	ditto "$app" "$installed"
	# One registered copy, so megamonitor:// links always reach the installed app.
	"$lsregister" -u "$app" 2>/dev/null || true
	"$lsregister" -f "$installed"
	echo "installed $installed ($config)"
else
	"$lsregister" -f "$app"
	echo "built $app ($config)"
fi
