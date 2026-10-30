#!/bin/bash
# Moves the installed app from its old bundle name to the new one: when ~/Applications/menubar-monitor.app exists (the
# app was called menubar-monitor before it became MegaMonitor), remembers whether it was a login item, makes Launch
# Services forget the old path and removes the old bundle. build.sh --install runs it before it copies the new bundle,
# so install.sh and the app's own Update Ready — Rebuild both get here. It changes nothing when the old bundle is gone.
#
# The identity stays menubar-monitor (bundle id, defaults, keychain, folders), so nothing but the bundle's path moves.
# A script can't unregister an SMAppService login item, and macOS keeps it under the old path, so the script leaves a
# marker in the Application Support folder and the new app registers the login item again at its first launch
# (LaunchAtLogin.refreshRegistrationIfMarked). Whether it was on comes from `sfltool dumpbtm`, which lists the
# background items without admin rights.
#
#   scripts/migrate-old-bundle.sh
#
# Environment (for the tests): HOME, and LSREGISTER, the path of lsregister.
set -euo pipefail

old=$HOME/Applications/menubar-monitor.app
lsregister=${LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}
support=$HOME/Library/Application\ Support/menubar-monitor

if [[ ! -d $old ]]; then
	exit 0
fi

# The record of the main app, "2.<bundle id>", has its disposition on the line before the identifier. The dump is read
# whole: grep -q would end the pipe early, and pipefail would take sfltool's broken pipe for a failure.
btm=$(sfltool dumpbtm 2>/dev/null || true)
if grep -B1 -E '^ +Identifier: 2\.local\.menubar-monitor$' <<<"$btm" | grep -q 'Disposition: \[enabled'; then
	mkdir -p "$support"
	: >"$support/refresh-login-item"
	echo '• open at login was on: MegaMonitor registers it again at its first launch'
fi

"$lsregister" -u "$old" 2>/dev/null || true
rm -rf "$old"
echo "✓ removed the old bundle $old"
