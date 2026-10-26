# Test helpers, sourced by tests/run.sh. Every test runs in its own sandbox: a copy of the tool with a team.conf, its own
# HOME (so its own cache, settings and ~/.zshrc), a fake curl that answers from routes, and recording fakes for
# everything that would make noise or touch the real system (sounds, dialogs, banners, browser, keychain).

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
JOB_ROOT=https://jenkins.test/job/project
GITLAB=https://gitlab.test

setup_sandbox() {
	sandbox=$(mktemp -d "${TMPDIR:-/tmp}/jenkins-menubar-test.XXXXXX")
	tool=$sandbox/tool
	mkdir -p "$tool/config" "$sandbox/home" "$sandbox/fakes" "$sandbox/curl" "$sandbox/keychain"
	cp -R "$repo_dir/plugins" "$repo_dir/bin" "$repo_dir/icons" "$tool/"
	cp "$repo_dir/config/team.example.conf" "$tool/config/"
	cat >"$tool/config/team.conf" <<-EOF
		jenkins_job_url=$JOB_ROOT/
		gitlab_url=$GITLAB
		gitlab_project=group/project
	EOF

	local name
	for name in curl security; do
		ln -s "$repo_dir/tests/fakes/$name" "$sandbox/fakes/$name"
	done
	for name in afplay say osascript open; do
		ln -s "$repo_dir/tests/fakes/record" "$sandbox/fakes/$name"
	done
	mkdir -p "$tool/notifier/Jenkins Watch.app/Contents/MacOS"
	ln -s "$repo_dir/tests/fakes/record" "$tool/notifier/Jenkins Watch.app/Contents/MacOS/jenkins-notifier"
	: >"$sandbox/curl/routes"
	: >"$sandbox/calls"

	export HOME=$sandbox/home PATH="$sandbox/fakes:$PATH" CALLS=$sandbox/calls FAKE_CURL=$sandbox/curl FAKE_KEYCHAIN=$sandbox/keychain
	JENKINS_MCP_BASIC_AUTH=$(printf 'me:jenkins-secret' | base64)
	export JENKINS_MCP_BASIC_AUTH
	unset GITLAB_TOKEN JENKINS_USER JENKINS_TOKEN
	cache=$HOME/Library/Caches/jenkins-menubar
	route_count=0
}

# Plugin tests get a recording jenkins-watch, so a finished build only shows up as a call; the watch tests run the real one.
fake_watch() {
	rm "$tool/bin/jenkins-watch"
	ln -s "$repo_dir/tests/fakes/record" "$tool/bin/jenkins-watch"
}

fail() {
	printf '%s\n' "$@" >&2
	[[ -s $sandbox/stderr ]] && printf -- '--- stderr of the tool:\n%s\n' "$(cat "$sandbox/stderr")" >&2
	exit 1
}

# assert_contains <text> <part> [name of the text]
assert_contains() {
	[[ $1 == *"$2"* ]] || fail "expected ${3:-the text} to contain: $2" "--- ${3:-text}:" "$1"
}

assert_not_contains() {
	[[ $1 != *"$2"* ]] || fail "expected ${3:-the text} not to contain: $2" "--- ${3:-text}:" "$1"
}

assert_equals() {
	[[ $1 == "$2" ]] || fail "expected ${3:-value}: $2" "actual: $1"
}

# ── The fake curl ──

# route <text in the URL or the posted data> <HTTP status | exit:<curl exit code>> [body]; a later route wins over an
# earlier one, so a test can change an answer between two runs.
route() {
	local file=''
	if (($# > 2)); then
		route_count=$((route_count + 1))
		file=$FAKE_CURL/body.$route_count
		printf '%s' "$3" >"$file"
	fi
	printf '%s\t%s\t%s\n' "$1" "$2" "$file" >>"$FAKE_CURL/routes"
}

# The requests of the last plugin_run (or since the sandbox started), one "URL<tab>data" line each.
requests() {
	cat "$FAKE_CURL/requests" 2>/dev/null
}

request_count() {
	requests | grep -cF -- "$1"
}

# ── Jenkins answers ──

# jenkins_jobs <job>:<contributor> …: the discovery answer, the jobs of the multibranch job with their MR authors.
jenkins_jobs() {
	route 'tree=jobs' 200 "$(jq -n '{jobs: [$ARGS.positional[] | split(":") | {name: .[0], actions: [{}, {contributor: .[1]}]}]}' --args "$@")"
}

# jenkins_build <job> <number> <building: true | false> <result | null> [MR title]: the job and its last build, in one
# answer for both the job's and the build's API.
jenkins_build() {
	local job=$1 number=$2 building=$3 result=$4 title=${5-Title of $1}
	local json
	json=$(jq -n --arg job "$job" --arg title "$title" --argjson number "$number" --argjson building "$building" \
		--arg result "$result" --argjson now "$(date +%s)" '
		(if $result == "null" then null else $result end) as $result
		| {timestamp: (($now - 3600) * 1000), estimatedDuration: 7200000, duration: (if $building then 0 else 1800000 end)} as $times
		| {
			displayName: $job,
			inQueue: false,
			actions: [{}, {objectDisplayName: $title, objectUrl: "https://gitlab.test/group/project/-/merge_requests/\($job | ltrimstr("MR-"))"}],
			lastBuild: ({number: $number, building: $building, result: $result} + $times)
		} + {building: $building, result: $result} + $times')
	route "/job/$job/api/json" 200 "$json"
	route "/job/$job/$number/api/json" 200 "$json"
}

# jenkins_stages <job> <number> <stage>:<status> …: the build's pipeline stages (wfapi/describe).
jenkins_stages() {
	local job=$1 number=$2
	shift 2
	route "/job/$job/$number/wfapi/describe" 200 "$(jq -n '{stages: [$ARGS.positional[] | split(":") | {name: .[0], status: .[1]}]}' --args "$@")"
}

# ── GitLab answers ──

# gitlab_answers <username> [my merge requests] [merge requests asking for my review]: GitLab's answer to the merge
# requests query, the lists as comma-separated gitlab_merge_request objects, and no work items.
gitlab_answers() {
	route currentUser 200 "$(jq -n --arg me "$1" --argjson mine "[${2:-}]" --argjson reviewing "[${3:-}]" \
		'{data: {currentUser: {username: $me, authored: {nodes: $mine}, assigned: {nodes: []}, reviewing: {nodes: $reviewing}}}}')"
	route withCommitted 200 '{"data": {"others": {"count": 0, "nodes": []}}}'
}

# gitlab_work_item_with_labels <label> …: GitLab's answer to the work items query, one work item with these labels.
gitlab_work_item_with_labels() {
	route withCommitted 200 "$(jq -n '{data: {others: {count: 1, nodes: [{
		title: "Item", webUrl: "https://gitlab.test/group/project/-/issues/1", reference: "group/project#1",
		updatedAt: "2026-01-01T00:00:00Z", labels: {nodes: [$ARGS.positional[] | {title: .}]}}]}}}' --args "$@")"
}

# gitlab_merge_request <iid> <title> <author> <detailedMergeStatus> [reviewer who has not reviewed yet]
gitlab_merge_request() {
	jq -nc --arg iid "$1" --arg title "$2" --arg author "$3" --arg status "$4" --arg reviewer "${5:-}" '{
		iid: $iid, title: $title, webUrl: "https://gitlab.test/group/project/-/merge_requests/\($iid)", draft: false,
		reference: "group/project!\($iid)", updatedAt: "2026-01-01T00:00:00Z", detailedMergeStatus: $status,
		author: {username: $author, name: $author}, headPipeline: {status: "SUCCESS"},
		diffStatsSummary: {additions: 1, deletions: 1, fileCount: 1},
		reviewers: {nodes: [if $reviewer == "" then empty
			else {username: $reviewer, mergeRequestInteraction: {reviewState: "UNREVIEWED", approved: false}} end]}
	}'
}

# ── Running the plugin ──

# Runs the plugin with Jenkins and GitLab due, like SwiftBar's next refresh; the menu ends up in $menu.
plugin_run() {
	rm -f "$cache/last-poll" "$cache/last-gitlab-poll"
	: >"$FAKE_CURL/requests"
	menu=$("$tool/plugins/jenkins.30s.sh" 2>>"$sandbox/stderr")
}

# Runs the plugin when nothing is due: it only renders the menu from the cache.
plugin_render() {
	menu=$("$tool/plugins/jenkins.30s.sh" 2>>"$sandbox/stderr")
}

# plugin_action <arguments>: a menu item's action, like --hide MR-1 7.
plugin_action() {
	"$tool/plugins/jenkins.30s.sh" "$@" >/dev/null 2>>"$sandbox/stderr"
}

# The first line, what the menubar shows.
menubar() {
	printf '%s\n' "$menu" | head -n 1
}

# ── Recorded calls ──

calls() {
	grep "^$1"$'\t' "$CALLS"
}

call_count() {
	grep -c "^$1"$'\t' "$CALLS"
}

# jenkins-watch runs in the background, so its call can come a moment after the plugin is done.
wait_for_call() {
	local tries=0
	until grep -q "^$1"$'\t' "$CALLS"; do
		tries=$((tries + 1))
		((tries > 30)) && fail "expected a call to $1" "--- calls:" "$(cat "$CALLS")"
		sleep 0.1
	done
}

# Gives a wrongly started background call the time to show up before checking that there is none.
assert_no_call() {
	sleep 0.3
	[[ $(call_count "$1") == 0 ]] || fail "expected no call to $1" "--- calls:" "$(cat "$CALLS")"
}
