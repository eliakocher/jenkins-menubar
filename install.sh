#!/bin/bash
# Installs menubar-monitor from this checkout: builds it into ~/Applications/menubar-monitor.app and opens it. Only the
# Command Line Tools are needed. The app remembers this checkout and offers "Update Ready — Rebuild" when it changes.
#
#   ./install.sh [--dry-run]
#   ./install.sh --retire-old [--dry-run]
#
#   --retire-old  after the trial, removes the old jenkins-menubar: unlinks its SwiftBar plugin, removes SwiftBar's
#                 login item (unless other plugins still need SwiftBar), removes the ~/bin/jenkins-watch link,
#                 unregisters the old helper app and, once you confirm, deletes the old caches, logs and keychain items
#   --dry-run     prints the commands that would change something, and changes nothing
set -euo pipefail

root=$(cd "$(dirname "$0")" && pwd)
app=$HOME/Applications/menubar-monitor.app
dry_run=false
retire=false
for arg in "$@"; do
	case $arg in
	--dry-run) dry_run=true ;;
	--retire-old) retire=true ;;
	*)
		echo "usage: $0 [--retire-old] [--dry-run]" >&2
		exit 2
		;;
	esac
done

step() { printf '\n▶ %s\n' "$*"; }

# quote <argument>: the argument as a shell word, so a dry run prints commands that can be copied.
quote() {
	local safe='^[A-Za-z0-9_./:=@%+,-]+$'
	if [[ $1 =~ $safe ]]; then
		printf '%s' "$1"
	else
		local escaped="'\\''"
		printf "'%s'" "${1//\'/$escaped}"
	fi
}

# change <command> [<argument>…]: runs a command that changes something; with --dry-run, only prints it. Everything
# that changes the system goes through here.
change() {
	if $dry_run; then
		printf 'would run:'
		local word
		for word in "$@"; do
			printf ' %s' "$(quote "$word")"
		done
		printf '\n'
	else
		"$@"
	fi
}

# change_quietly <command> [<argument>…]: like change, without the command's own output.
change_quietly() {
	if $dry_run; then
		change "$@"
	else
		"$@" >/dev/null
	fi
}

lsregister() {
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister "$@"
}

# The old tool, jenkins-menubar: a SwiftBar plugin, the jenkins-watch command and a helper app, "Jenkins Watch.app",
# with its caches, logs and keychain items under the name jenkins-menubar.
old_plugin_name=jenkins.30s.sh
old_caches=$HOME/Library/Caches/jenkins-menubar
old_logs=$HOME/Library/Logs/jenkins-menubar
old_service=jenkins-menubar
old_helper_id=local.jenkins-menubar.notifier
accounts='JENKINS_MCP_BASIC_AUTH GITLAB_TOKEN'
import_marker="$HOME/Library/Application Support/menubar-monitor/legacy-import.json"

# swiftbar_plugin_folder: SwiftBar's plugin folder, or nothing.
swiftbar_plugin_folder() {
	local folder
	folder=$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)
	folder=${folder/#\~/$HOME}
	printf '%s' "${folder%/}"
}

# is_old_tool_file <file>: whether a file is the old plugin or the old jenkins-watch, which keep their caches and logs
# under jenkins-menubar. A link counts by the file it links to.
is_old_tool_file() {
	grep -q -e 'Library/Caches/jenkins-menubar' -e 'Library/Logs/jenkins-menubar' "$1" 2>/dev/null
}

old_tool_present() {
	local plugins
	plugins=$(swiftbar_plugin_folder)
	if [[ -n $plugins ]] && is_old_tool_file "$plugins/$old_plugin_name"; then
		return 0
	fi
	is_old_tool_file "$HOME/bin/jenkins-watch"
}

# wait_for_exit <process>: waits up to 5 seconds for a process to end.
wait_for_exit() {
	local tries=0
	while pgrep -x "$1" >/dev/null; do
		if ((tries == 50)); then
			echo "✗ $1 did not quit; quit it from its menu and run this again" >&2
			exit 1
		fi
		sleep 0.1
		tries=$((tries + 1))
	done
}

install_app() {
	step 'Requirements'
	local version
	version=$(sw_vers -productVersion)
	if ((${version%%.*} < 26)); then
		echo "✗ menubar-monitor needs macOS 26 or later; this Mac runs macOS $version." >&2
		exit 1
	fi
	if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swift >/dev/null 2>&1; then
		echo '✗ The Command Line Tools are needed: run  xcode-select --install  and then this script again.' >&2
		exit 1
	fi
	echo "✓ $(xcode-select -p)"

	step 'Build and install'
	change "$root/build.sh" --install

	step 'Start'
	# A running copy keeps running the old code, and open would only bring it forward.
	if pgrep -x menubar-monitor >/dev/null; then
		change pkill -x menubar-monitor || true
		if ! $dry_run; then
			wait_for_exit menubar-monitor
		fi
	fi
	change open "$app"
	echo '✓ The welcome flow takes it from here: what it imported, the team values, the tokens and the notifications.'
	if old_tool_present; then
		echo
		echo 'The old jenkins-menubar still runs next to it. After the trial, remove it with:  ./install.sh --retire-old'
	fi
}

# The old tool's folders, one per line, whose helper apps get unregistered. This checkout was one before the rewrite.
old_folders=''

# add_old_folder <folder>: adds a folder to old_folders, once.
add_old_folder() {
	local folder
	folder=$(realpath "$1" 2>/dev/null) || return 0
	if ! grep -Fxq -- "$folder" <<<"$old_folders"; then
		old_folders=$old_folders$folder$'\n'
	fi
}

# swiftbar_needed is true when other plugins still use SwiftBar, so it stays a login item and keeps running.
swiftbar_needed=false

unlink_plugin() {
	step 'SwiftBar plugin'
	local plugins plugin target others=''
	plugins=$(swiftbar_plugin_folder)
	plugin=$plugins/$old_plugin_name
	if [[ -n $plugins && -d $plugins ]]; then
		others=$(ls -A "$plugins" | grep -v -e '^\.' -e "^$old_plugin_name\$" || true)
	fi
	if [[ -n $others ]]; then
		swiftbar_needed=true
	fi
	if [[ -z $plugins ]] || [[ ! -e $plugin && ! -L $plugin ]]; then
		echo '✓ SwiftBar runs no jenkins-menubar plugin'
	elif [[ -L $plugin ]]; then
		target=$(realpath "$plugin" 2>/dev/null || true)
		if [[ -n $target ]] && ! is_old_tool_file "$target"; then
			echo "• $plugin links to $target, which isn't the old plugin, so it stays"
			swiftbar_needed=true
			return
		fi
		if [[ -n $target ]]; then
			add_old_folder "$(dirname "$(dirname "$target")")"
		fi
		change rm "$plugin"
		echo "✓ unlinked $plugin"
	elif ! is_old_tool_file "$plugin"; then
		echo "• $plugin isn't the old plugin, so it stays"
		swiftbar_needed=true
	elif [[ -d $plugins/../notifier || -f $plugins/../bin/jenkins-watch ]]; then
		# The old install.sh made the old tool's own plugins/ SwiftBar's plugin folder when SwiftBar had none.
		add_old_folder "$(dirname "$plugins")"
		if [[ -n $others ]]; then
			echo "• SwiftBar's plugin folder is the old tool's $plugins, and other plugins are in it too:"
			echo '  move them to a folder of their own and choose it in SwiftBar → Settings.'
		else
			change defaults delete com.ameba.SwiftBar PluginDirectory
			echo "✓ SwiftBar no longer uses $plugins"
		fi
	else
		change rm "$plugin"
		echo "✓ removed the copy $plugin"
	fi
}

remove_swiftbar_login_item() {
	step 'SwiftBar at login'
	if $swiftbar_needed; then
		echo '• SwiftBar stays a login item and keeps running: other plugins use it'
		return
	fi
	local items
	if ! items=$(osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null); then
		echo "✗ could not read the login items; remove SwiftBar in System Settings → General → Login Items if it's there"
	elif [[ ", $items, " == *", SwiftBar, "* ]]; then
		if change_quietly osascript -e 'tell application "System Events" to delete login item "SwiftBar"'; then
			echo '✓ removed SwiftBar from the login items'
		else
			echo '✗ could not remove it; do it in System Settings → General → Login Items'
		fi
	else
		echo '✓ SwiftBar is no login item'
	fi
	if pgrep -x SwiftBar >/dev/null; then
		change pkill -x SwiftBar || true
		echo '✓ quit SwiftBar'
	fi
}

remove_jenkins_watch() {
	step 'jenkins-watch'
	local watch=$HOME/bin/jenkins-watch target
	if [[ -L $watch ]]; then
		target=$(realpath "$watch" 2>/dev/null || true)
		if [[ -n $target ]] && ! is_old_tool_file "$target"; then
			echo "• ~/bin/jenkins-watch links to $target, which isn't the old command, so it stays"
			return
		fi
		if [[ -n $target ]]; then
			add_old_folder "$(dirname "$(dirname "$target")")"
		fi
		change rm "$watch"
		echo '✓ removed the link ~/bin/jenkins-watch'
	elif [[ -e $watch ]]; then
		echo "• ~/bin/jenkins-watch isn't a link to the old command, so it stays"
	else
		echo '✓ no ~/bin/jenkins-watch'
	fi
}

unregister_helper() {
	step 'Helper app'
	if pgrep -x jenkins-notifier >/dev/null; then
		change pkill -x jenkins-notifier || true
		echo '✓ quit the helper app'
	fi
	local folder helper found=false
	while IFS= read -r folder; do
		helper="$folder/notifier/Jenkins Watch.app"
		if [[ -n $folder && -d $helper ]]; then
			change lsregister -u "$helper"
			echo "✓ unregistered $helper"
			found=true
		fi
	done <<<"$old_folders"
	if ! $found; then
		echo '✓ no old helper app'
	fi
}

delete_old_data() {
	step 'Old caches, logs and keychain items'
	if [[ ! -e $import_marker ]]; then
		echo "• menubar-monitor hasn't imported from the old tool yet: open it once, then run this again to delete them."
		return
	fi
	local found='' account delete_accounts='' helper_defaults=false answer=''
	if [[ -d $old_caches ]]; then
		found=$found"  $old_caches"$'\n'
	fi
	if [[ -d $old_logs ]]; then
		found=$found"  $old_logs"$'\n'
	fi
	for account in $accounts; do
		if ! security find-generic-password -s "$old_service" -a "$account" >/dev/null 2>&1; then
			continue
		fi
		# The import copied the tokens; one it couldn't copy stays, so it isn't lost.
		if security find-generic-password -s menubar-monitor -a "$account" >/dev/null 2>&1; then
			delete_accounts="$delete_accounts $account"
			found=$found"  the keychain item $old_service $account"$'\n'
		else
			echo "• keeps the keychain item $old_service $account: menubar-monitor has no copy of it yet"
		fi
	done
	if defaults read "$old_helper_id" >/dev/null 2>&1; then
		helper_defaults=true
		found=$found"  the helper app's preferences ($old_helper_id)"$'\n'
	fi
	if [[ -z $found ]]; then
		echo '✓ nothing left'
		return
	fi
	echo 'Left from the old tool:'
	printf '%s' "$found"
	printf 'Delete them? [y/N] '
	read -r answer || true
	if [[ ! -t 0 ]]; then
		echo
	fi
	case $answer in
	[yY] | [yY][eE][sS]) ;;
	*)
		echo '• kept them'
		return
		;;
	esac
	if [[ -d $old_caches ]]; then
		change rm -rf "$old_caches"
	fi
	if [[ -d $old_logs ]]; then
		change rm -rf "$old_logs"
	fi
	for account in $delete_accounts; do
		change_quietly security delete-generic-password -s "$old_service" -a "$account"
	done
	if $helper_defaults; then
		change defaults delete "$old_helper_id"
	fi
	echo '✓ deleted them'
}

retire_old_tool() {
	if [[ ! -d $app ]]; then
		echo "✗ menubar-monitor isn't installed: run ./install.sh first, and retire the old tool after the trial." >&2
		exit 1
	fi
	add_old_folder "$root"
	unlink_plugin
	remove_swiftbar_login_item
	remove_jenkins_watch
	unregister_helper
	delete_old_data

	step 'Left to you'
	local folder
	while IFS= read -r folder; do
		if [[ -n $folder && $folder != "$(realpath "$root")" ]]; then
			echo "• The old tool's folder $folder can go (a worktree: git worktree remove $(quote "$folder"))."
		fi
	done <<<"$old_folders"
	if ! $swiftbar_needed && [[ -d /Applications/SwiftBar.app ]]; then
		echo '• SwiftBar and jq stay installed; if nothing else uses them: brew uninstall --cask swiftbar && brew uninstall jq'
	fi
	if grep -qE '^[[:space:]]*export (JENKINS_MCP_BASIC_AUTH|GITLAB_TOKEN)=' "$HOME/.zshrc" 2>/dev/null; then
		echo '• ~/.zshrc still exports JENKINS_MCP_BASIC_AUTH or GITLAB_TOKEN. menubar-monitor keeps its own copies in'
		echo '  the keychain, so remove the exports unless something else uses them.'
	fi
}

if $retire; then
	retire_old_tool
else
	install_app
fi
if $dry_run; then
	printf '\nA dry run: nothing was changed.\n'
fi
