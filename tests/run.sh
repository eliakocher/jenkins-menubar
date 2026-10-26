#!/bin/bash
# Runs every test_* function of tests/*_test.sh, each in its own sandbox (see tests/lib.sh).
# Usage: tests/run.sh [part of a test name]
tests_dir=$(cd "$(dirname "$0")" && pwd)
. "$tests_dir/lib.sh"
for file in "$tests_dir"/*_test.sh; do
	. "$file"
done

run_test() {
	(
		setup_sandbox
		trap 'rm -rf "$sandbox"' EXIT
		[[ $1 == test_plugin_* ]] && fake_watch
		"$1"
	)
}

passed=0
failed=0
for name in $(declare -F | awk '{ print $3 }' | grep '^test_' | grep -e "${1:-}"); do
	if output=$(run_test "$name" 2>&1); then
		passed=$((passed + 1))
		printf '✓ %s\n' "$name"
	else
		failed=$((failed + 1))
		printf '✗ %s\n' "$name"
		printf '%s\n' "$output" | sed 's/^/    /'
	fi
done
printf '\n%d passed, %d failed\n' "$passed" "$failed"
((failed == 0))
