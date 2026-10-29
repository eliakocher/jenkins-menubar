#!/bin/bash
# Screenshots gallery entries, for the design reviews: docs/design/shots/<id>-<appearance>.png.
#
#   scripts/gallery-shots.sh <screen or id>... [--appearance light|dark|light-hc|dark-hc]... [-- <gallery options>]
#   scripts/gallery-shots.sh all
#
# Builds the debug app (which has the gallery), then for each appearance (light and dark unless some are given) opens the
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
	appearances=(light dark)
fi

# Several lanes may take screenshots at the same time. The runs take turns, because they share the debug app, the
# manifest and the gallery's windows; a lock whose owner is gone is taken over.
lock=$root/build/gallery.lock
mkdir -p "$root/build"
waited=0
until mkdir "$lock" 2>/dev/null; do
	owner=$(cat "$lock/pid" 2>/dev/null || true)
	if [[ -n $owner ]] && ! kill -0 "$owner" 2>/dev/null; then
		rm -rf "$lock"
		continue
	fi
	((waited == 0)) && echo "another gallery run is going (pid ${owner:-?}); waiting for it" >&2
	if ((waited >= 1800)); then
		echo "still locked after 30 minutes: $lock" >&2
		exit 1
	fi
	sleep 1
	waited=$((waited + 1))
done
echo $$ >"$lock/pid"
gallery=
trap '[[ -n $gallery ]] && kill "$gallery" 2>/dev/null; rm -rf "$lock"; true' EXIT

"$root/build.sh" --debug >/dev/null
# The run starts a copy of its own, so that a release build another lane starts meanwhile can't swap the app.
gallery_app=$root/build/gallery/menubar-monitor.app
rm -rf "$gallery_app"
mkdir -p "$(dirname "$gallery_app")" "$shots"
ditto "$app" "$gallery_app"

for appearance in "${appearances[@]}"; do
	rm -f "$manifest"
	# Bash 3.2, which macOS ships, treats an empty array as unset under set -u.
	"$gallery_app/Contents/MacOS/menubar-monitor" --gallery --appearance "$appearance" --manifest "$manifest" \
		${only[@]+"${only[@]}"} ${extra[@]+"${extra[@]}"} >/dev/null &
	gallery=$!
	# A run of a few hundred entries opens as many windows before it writes the manifest.
	for _ in $(seq 600); do
		[[ -f $manifest ]] && break
		if ! kill -0 "$gallery" 2>/dev/null; then
			wait "$gallery" || true
			echo "the gallery quit before writing $manifest" >&2
			exit 1
		fi
		sleep 0.1
	done
	if [[ ! -f $manifest ]]; then
		echo "no $manifest after 60 seconds" >&2
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
