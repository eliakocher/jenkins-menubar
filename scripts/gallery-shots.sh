#!/bin/bash
# Screenshots gallery entries, for the design reviews: docs/design/shots/<id>-<appearance>.png.
#
#   scripts/gallery-shots.sh <screen or id>... [--appearance light|dark|light-hc|dark-hc]... [-- <gallery options>]
#   scripts/gallery-shots.sh all
#
# Builds the debug app (which has the gallery), then for each appearance (all four unless some are given) opens the
# gallery, reads build/gallery/manifest.json, which maps each entry id to its window number, captures each window with
# `screencapture -l`, and quits the gallery. Only the gallery's own windows are captured, never the screen. The gallery
# stays in the background and doesn't take the keyboard focus. Options after -- go to the gallery as they are, such as
# --type-size or --reduce-transparency; the file names don't record them.
#
# screencapture needs Screen Recording permission for the terminal, which the user grants once in System Settings.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
app=$root/build/menubar-monitor.app
manifest=$root/build/gallery/manifest.json
shots=$root/docs/design/shots

if [[ $# -eq 0 ]]; then
	sed -n '4,5s/^# *//p' "$0" >&2
	exit 2
fi
only=()
appearances=()
extra=()
while [[ $# -gt 0 ]]; do
	case $1 in
	--appearance)
		appearances+=("$2")
		shift 2
		;;
	--)
		shift
		extra=("$@")
		break
		;;
	all)
		shift
		;;
	-*)
		echo "unknown option $1" >&2
		exit 2
		;;
	*)
		only+=(--only "$1")
		shift
		;;
	esac
done
if [[ ${#appearances[@]} -eq 0 ]]; then
	appearances=(light dark light-hc dark-hc)
fi

"$root/build.sh" --debug >/dev/null
mkdir -p "$shots"

gallery=
trap '[[ -n $gallery ]] && kill "$gallery" 2>/dev/null; true' EXIT
for appearance in "${appearances[@]}"; do
	rm -f "$manifest"
	# Bash 3.2, which macOS ships, treats an empty array as unset under set -u.
	"$app/Contents/MacOS/menubar-monitor" --gallery --appearance "$appearance" --manifest "$manifest" \
		${only[@]+"${only[@]}"} ${extra[@]+"${extra[@]}"} >/dev/null &
	gallery=$!
	for _ in $(seq 100); do
		[[ -f $manifest ]] && break
		if ! kill -0 "$gallery" 2>/dev/null; then
			wait "$gallery" || true
			echo "the gallery quit before writing $manifest" >&2
			exit 1
		fi
		sleep 0.1
	done
	if [[ ! -f $manifest ]]; then
		echo "no $manifest after 10 seconds" >&2
		exit 1
	fi
	/usr/bin/jq -r 'to_entries[] | "\(.key) \(.value)"' "$manifest" | while read -r id window; do
		shot=$shots/$id-$appearance.png
		if ! screencapture -x -o -l "$window" "$shot" || [[ ! -s $shot ]]; then
			echo "cannot capture $id (window $window): does the terminal have Screen Recording permission?" >&2
			exit 1
		fi
		echo "$shot"
	done
	kill "$gallery" 2>/dev/null || true
	wait "$gallery" 2>/dev/null || true
	gallery=
done
