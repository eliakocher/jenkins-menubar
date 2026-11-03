#!/bin/bash
# Refreshes the README's screenshots: docs/screenshots/<name>.png, in dark, from the gallery's made-up fixtures.
#
#   scripts/readme-shots.sh [name]...
#
# With no names, renders them all. It runs scripts/gallery-shots.sh (which builds the debug app, takes turns with the
# other gallery runs and captures only the gallery's own windows) with `--readme`, so the windows carry the app's own
# titles and no entry ids, and copies each shot to docs/screenshots/ under a stable name. A PNG over 1.5 MB is scaled
# down. The entries are in Sources/MenubarUI/Gallery/ReadmeGallery.swift (the `readme.*` ones, a few of
# them reusing the other gallery entries). Needs Screen Recording permission for the terminal, like gallery-shots.sh.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
shots=$root/docs/design/shots
out=$root/docs/screenshots
limit=1500000

# name:gallery entry
all=(
	main-window:readme.main-window
	pane:readme.pane
	pipelines:readme.pipelines
	merge-request:readme.merge-request
	ask-claude:readme.ask-claude
	discussion:readme.discussion
	why-failed:readme.why-failed
	rebuild-sheet:readme.rebuild-sheet
	work-item:readme.work-item
	slots:readme.slots
	inbox:readme.inbox
	inbox-panel:readme.inbox-panel
	digest:readme.digest
	workspaces:readme.workspaces
	settings-menu-bar:readme.settings-menu-bar
	alert:readme.alert
)

chosen=()
if [[ $# -eq 0 ]]; then
	chosen=("${all[@]}")
else
	for name in "$@"; do
		found=
		for pair in "${all[@]}"; do
			if [[ ${pair%%:*} == "$name" ]]; then
				chosen+=("$pair")
				found=1
			fi
		done
		if [[ -z $found ]]; then
			echo "unknown shot $name; known: $(printf '%s ' "${all[@]%%:*}")" >&2
			exit 2
		fi
	done
fi

mkdir -p "$out"
entries=()
for pair in "${chosen[@]}"; do
	entries+=("${pair#*:}")
done
"$root/scripts/gallery-shots.sh" "${entries[@]}" --appearance dark -- --readme >/dev/null

for pair in "${chosen[@]}"; do
	name=${pair%%:*}
	src=$shots/${pair#*:}-dark.png
	dst=$out/$name.png
	cp "$src" "$dst"
	width=$(sips -g pixelWidth "$dst" | awk '/pixelWidth/ {print $2}')
	size=$(stat -f %z "$dst")
	while ((size > limit && width > 800)); do
		width=$((width * 85 / 100))
		sips --resampleWidth "$width" "$dst" >/dev/null
		size=$(stat -f %z "$dst")
	done
	echo "$dst (${width}px wide, $((size / 1024)) KB)"
done
