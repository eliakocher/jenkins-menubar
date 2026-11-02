#!/bin/bash
# Refuses names that must not reach the public repository, such as the company's name in any case, in every file git
# would commit: tracked files, and untracked ones that aren't ignored, their names and their contents. build.sh runs it
# and stops; test.sh runs it and only warns.
#
# The pattern is written so that it doesn't match itself, so this file can be committed too. Text inside images can't
# be checked: look at screenshots before adding them. Commit messages and the commit's author email aren't checked.
#
# Besides its own pattern it reads more from `.claude/forbidden-names.txt` when that file exists: one extended regex per
# line, `#` comments and blank lines skipped. The file is git-ignored (so is all of `.claude/`), which keeps the real
# label names and team names out of the repository; it is checked that git really ignores it before it is read.
set -euo pipefail

forbidden='u[n]blu'

cd "$(dirname "$0")/.."
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	exit 0 # not a checkout, so nothing gets committed from here
fi

# the extra patterns of the local, git-ignored file, joined with |
extra_file=".claude/forbidden-names.txt"
if [[ -f $extra_file ]]; then
	if ! git check-ignore -q "$extra_file"; then
		echo "$extra_file must be git-ignored: it holds the real names" >&2
		exit 1
	fi
	extra=$(grep -v -E '^[[:space:]]*(#|$)' "$extra_file" | paste -sd'|' - || true)
	[[ -z $extra ]] || forbidden="$forbidden|$extra"
fi

refuse() {
	echo "$1" >&2
	echo "$2" | sed 's/^/  /' >&2
	exit 1
}

names=$(git ls-files --cached --others --exclude-standard | grep -i -E "$forbidden" || true)
[[ -z $names ]] || refuse "File names contain a forbidden name:" "$names"
lines=$(git ls-files -z --cached --others --exclude-standard | xargs -0 grep -s -I -n -i -E "$forbidden" -- || true)
[[ -z $lines ]] || refuse "Files contain a forbidden name; use made-up names (see team.example.json):" "$lines"
