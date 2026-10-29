#!/bin/bash
# Compares the states the design specs list with the gallery entries: the check of Task 4.9 that every state in the
# specs has a gallery entry.
#
#   scripts/gallery-coverage.sh [<screen>...]           the spec states no gallery entry has yet
#   scripts/gallery-coverage.sh --extras [<screen>...]  the gallery entries no spec lists
#
# Without screens, it checks every spec marked approved (`Status: approved…`). A spec state is a `<screen>.<state>` id
# in backticks anywhere in docs/design/<screen>.md. A gallery entry counts when its source spells the slugs out:
# `GalleryEntry(screen: "panel", state: "loading", …)`. This is a script and not a Swift test because docs/design/
# isn't in git.
set -euo pipefail

cd "$(dirname "$0")/.."
mode=missing
if [[ ${1:-} == --extras ]]; then
	mode=extras
	shift
fi
if [[ ! -d docs/design ]]; then
	echo "docs/design/ isn't here (it isn't in git); nothing to compare"
	exit 0
fi

screens=("$@")
if [[ ${#screens[@]} -eq 0 ]]; then
	for spec in docs/design/*.md; do
		[[ $spec == docs/design/README.md ]] && continue
		grep -qE '^Status: approved' "$spec" && screens+=("$(basename "$spec" .md)")
	done
fi
if [[ ${#screens[@]} -eq 0 ]]; then
	echo "no approved spec yet"
	exit 0
fi

# Ids may wrap across lines, so the lines are joined and the spaces squeezed, as in features-coverage.sh.
spec_ids() {
	local screen
	for screen in "${screens[@]}"; do
		tr '\n' ' ' <"docs/design/$screen.md" | tr -s ' ' | grep -oE "\`$screen\.[a-z0-9-]+\`" | tr -d '\`' || true
	done | sort -u
}
gallery_ids() {
	git ls-files -co --exclude-standard Sources/MenubarUI | grep -E '\.swift$' | tr '\n' '\0' | xargs -0 cat |
		tr '\n' ' ' | tr -s ' ' |
		grep -oE 'GalleryEntry\( ?screen: "[a-z0-9-]+", ?state: "[a-z0-9-]+"' |
		sed -E 's/.*screen: "([a-z0-9-]+)", ?state: "([a-z0-9-]+)"/\1.\2/' | sort -u || true
}

if [[ $mode == extras ]]; then
	comm -13 <(spec_ids) <(gallery_ids)
	exit 0
fi
missing=$(comm -23 <(spec_ids) <(gallery_ids))
[[ -n $missing ]] && echo "$missing"
total=$(spec_ids | grep -cE . || true)
open=$(grep -cE . <<<"$missing" || true)
echo "-- $((total - open)) of $total spec states have a gallery entry (${screens[*]}); per screen, still open:"
{ grep -oE '^[a-z0-9-]+' <<<"$missing" || true; } | sort | uniq -c | awk '{printf "%s %s  ", $2, $1} END {print ""}'
