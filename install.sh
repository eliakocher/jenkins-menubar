#!/bin/bash
# Sets up the Jenkins/GitLab menubar from this folder: dependencies, the "Jenkins" notifier app, SwiftBar and the tokens.
# The tool runs from here, so keep the folder where it is (for example ~/tools/jenkins-menubar).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)

step() { printf '\n▶ %s\n' "$*"; }

step 'Team configuration'
if [[ ! -f $here/config/team.conf ]]; then
	cp "$here/config/team.example.conf" "$here/config/team.conf"
	echo "Fill in $here/config/team.conf (your Jenkins job and GitLab project, or get it from your team), then run this script again."
	exit 1
fi
gitlab_url=$(awk 'index($0, "gitlab_url=") == 1 { value = substr($0, 12) } END { print value }' "$here/config/team.conf")
echo '✓ config/team.conf'

if ! command -v brew >/dev/null; then
	echo 'Homebrew is needed: https://brew.sh' >&2
	exit 1
fi
step 'Dependencies'
command -v jq >/dev/null || brew install jq
[[ -d /Applications/SwiftBar.app ]] || brew install --cask swiftbar
if ! xcrun --find swiftc >/dev/null 2>&1; then
	echo 'The Xcode Command Line Tools are needed for the notifier: run  xcode-select --install  and then this script again.' >&2
	exit 1
fi
chmod +x "$here/plugins/jenkins.30s.sh" "$here/bin/jenkins-watch" "$here/notifier/build.sh"

step 'jenkins-watch for the terminal'
mkdir -p "$HOME/bin"
ln -sf "$here/bin/jenkins-watch" "$HOME/bin/jenkins-watch"
echo "~/bin/jenkins-watch → $here/bin/jenkins-watch (~/bin must be on your PATH)"

step 'Notifier app (notifier/Jenkins Watch.app)'
"$here/notifier/build.sh"

step 'SwiftBar plugin'
plugins=$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)
if [[ -z $plugins || $plugins == "$here/plugins" ]]; then
	defaults write com.ameba.SwiftBar PluginDirectory -string "$here/plugins"
	echo "SwiftBar's plugin folder: $here/plugins"
else
	# SwiftBar already has a plugin folder, maybe with other plugins: link this one into it.
	ln -sf "$here/plugins/jenkins.30s.sh" "$plugins/jenkins.30s.sh"
	echo "linked into SwiftBar's plugin folder $plugins"
fi

step 'Start SwiftBar at login'
# SwiftBar's own StartAtLogin preference registers nothing unless it is toggled in its window, so add a real login item.
if osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null | grep -q SwiftBar; then
	echo '✓ SwiftBar is a login item'
elif osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/SwiftBar.app", hidden:false}' >/dev/null 2>&1; then
	echo '✓ added SwiftBar to the login items'
else
	echo '✗ could not add it; do it in System Settings → General → Login Items → + → SwiftBar'
fi

step 'Tokens in ~/.zshrc'
missing=0
if ! grep -qE '^[[:space:]]*export JENKINS_MCP_BASIC_AUTH=' "$HOME/.zshrc" 2>/dev/null; then
	missing=1
	echo '✗ JENKINS_MCP_BASIC_AUTH is missing. Add:  export JENKINS_MCP_BASIC_AUTH=<base64 of jenkins-user:api-token>'
	echo '  (the API token is in Jenkins → your user → Security)'
else
	echo '✓ JENKINS_MCP_BASIC_AUTH'
fi
if ! grep -qE '^[[:space:]]*export GITLAB_TOKEN=' "$HOME/.zshrc" 2>/dev/null; then
	missing=1
	echo '✗ GITLAB_TOKEN is missing. Create a token with the read_api scope:'
	echo "  ${gitlab_url%/}/-/user_settings/personal_access_tokens?name=Jenkins%20menubar&scopes=read_api"
	echo '  and add:  export GITLAB_TOKEN=<the token>'
else
	echo '✓ GITLAB_TOKEN'
fi

step 'Start'
open -a SwiftBar
echo 'A sample banner follows: click "Allow" when macOS asks whether "Jenkins" may send notifications.'
"$here/bin/jenkins-watch" --test --banner >/dev/null 2>&1 || true
((missing)) && printf '\nAdd the missing token(s) to ~/.zshrc; the menu picks them up within 30 seconds.\n'
echo 'Done.'
