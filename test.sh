#!/bin/bash
# Runs the Swift Testing tests.
#
#   ./test.sh [filter]
#
# With only the Command Line Tools, a plain `swift test` finds neither the Testing macros nor Testing.framework: when
# the CLT are the active developer directory, this adds the paths to both.
set -euo pipefail

cd "$(dirname "$0")"
clt=/Library/Developer/CommandLineTools
developer_dir=${DEVELOPER_DIR:-$(xcode-select -p)}
args=()
if [[ ${developer_dir%/} == "$clt" ]]; then
	frameworks=$clt/Library/Developer/Frameworks
	args+=(-Xswiftc -plugin-path -Xswiftc "$clt/usr/lib/swift/host/plugins/testing"
		-Xswiftc -F -Xswiftc "$frameworks" -Xlinker -rpath -Xlinker "$frameworks")
fi
if [[ $# -gt 0 ]]; then
	args+=(--filter "$1")
fi
# Only a warning here, so that one file doesn't stop everyone's tests; build.sh refuses it.
scripts/check-names.sh || echo 'warning: remove the names above before committing; build.sh refuses them' >&2
# TemporaryDefaults empties its suite at the end, but cfprefsd keeps the empty plist in ~/Library/Preferences. The
# ones of earlier runs go here; the ten minutes spare those of a run that another lane has going right now.
find "$HOME/Library/Preferences" -maxdepth 1 -name 'menubar-monitor-tests.*.plist' -mmin +10 -print0 | xargs -0 rm -f
# Bash 3.2, which macOS ships, treats an empty array as unset under set -u.
exec swift test ${args[@]+"${args[@]}"}
