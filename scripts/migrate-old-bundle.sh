#!/bin/bash
# Carries the installed app over from its former names. build.sh --install runs it before it copies the new bundle, so
# install.sh and the app's own Update Ready — Rebuild both get here.
#
# - The bundle's path: when ~/Applications/menubar-monitor.app exists (the app's file name before MegaMonitor.app), it
#   makes Launch Services forget the old path and removes that bundle.
# - Open at login: the login item is an SMAppService item, tied to the bundle id, which was local.menubar-monitor
#   before Task 7.12 and is local.megamonitor now. A script can't register or unregister one, so when the former item
#   was on, the script leaves the marker refresh-login-item in the new Application Support folder and the new app
#   registers its own login item at its first launch (LaunchAtLogin.refreshRegistrationIfMarked). Whether it was on
#   comes from `sfltool dumpbtm`, which lists the background items without admin rights. This look happens once
#   (the file identity-login-item-checked records it), so turning open at login off later is never undone, and again
#   whenever the old bundle is still there.
#
# The preferences, the tokens and the folders aren't the script's: the app copies them itself (IdentityMigration). The
# script never deletes anything but the old bundle; `./install.sh --retire-old` removes the former data.
#
#   scripts/migrate-old-bundle.sh
#
# Environment (for the tests): HOME, and LSREGISTER, the path of lsregister.
set -euo pipefail

old=$HOME/Applications/menubar-monitor.app
lsregister=${LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}
support=$HOME/Library/Application\ Support/MegaMonitor
checked=$support/identity-login-item-checked

if [[ ! -d $old && -e $checked ]]; then
	exit 0
fi

# The record of the main app, "2.<bundle id>", has its disposition on the line before the identifier. The dump is read
# whole: grep -q would end the pipe early, and pipefail would take sfltool's broken pipe for a failure.
btm=$(sfltool dumpbtm 2>/dev/null || true)
mkdir -p "$support"
if grep -B1 -E '^ +Identifier: 2\.local\.menubar-monitor$' <<<"$btm" | grep -q 'Disposition: \[enabled'; then
	: >"$support/refresh-login-item"
	echo '• open at login was on: MegaMonitor registers it again at its first launch'
fi
: >"$checked"

if [[ -d $old ]]; then
	"$lsregister" -u "$old" 2>/dev/null || true
	rm -rf "$old"
	echo "✓ removed the old bundle $old"
fi
