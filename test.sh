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
# Bash 3.2, which macOS ships, treats an empty array as unset under set -u.
exec swift test ${args[@]+"${args[@]}"}
