#!/bin/bash
# Compares the tests docs/FEATURES.md names with the Swift Testing tests in Tests/: the parity check of Task 7.2.
#
#   scripts/features-coverage.sh [<id prefix>]          the FEATURES names no test has yet, such as PIPE or PIPE-02
#   scripts/features-coverage.sh --extras [<id prefix>] the tests FEATURES doesn't name, which are fine to have
#
# A test counts when its display name equals a name FEATURES lists. Manual checks (`Manual: …`) aren't counted.
set -euo pipefail

cd "$(dirname "$0")/.."
mode=missing
if [[ ${1:-} == --extras ]]; then
	mode=extras
	shift
fi
prefix=${1:-}

# Names in FEATURES.md are in backticks and may wrap across lines, so the lines are joined and the spaces squeezed.
spec_names() {
	tr '\n' ' ' <docs/FEATURES.md | tr -s ' ' | grep -oE '`[A-Z]+-[0-9]{2} [^`]+`' | tr -d '`' | sort -u
}
# A display name may start on the line after `@Test(`, so the test files are joined too.
test_names() {
	find Tests -name '*.swift' -print0 | xargs -0 cat | tr '\n' ' ' | tr -s ' ' |
		grep -oE '@Test\( ?"[^"]+"' | sed -E 's/^@Test\( ?"//; s/"$//' | sort -u
}

if [[ $mode == extras ]]; then
	comm -13 <(spec_names) <(test_names) | grep -E "^$prefix" || true
	exit 0
fi
missing=$(comm -23 <(spec_names) <(test_names) | grep -E "^$prefix" || true)
[[ -n $missing ]] && echo "$missing"
total=$(spec_names | grep -cE "^$prefix" || true)
open=$(grep -cE . <<<"$missing" || true)
echo "-- $((total - open)) of $total FEATURES test names have a test${prefix:+ (prefix $prefix)}; per area, still open:"
{ grep -oE '^[A-Z]+' <<<"$missing" || true; } | sort | uniq -c | awk '{printf "%s %s  ", $2, $1} END {print ""}'
