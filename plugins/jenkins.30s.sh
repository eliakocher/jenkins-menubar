#!/bin/bash
# <xbar.title>My Jenkins pipelines</xbar.title>
# <xbar.desc>Jenkins builds of your own merge requests, with an alert when one finishes.</xbar.desc>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>

export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
# Character-based string lengths for truncating titles; SwiftBar starts plugins without a locale.
export LC_ALL=en_US.UTF-8

DISCOVERY_MINUTES=10

self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
# SwiftBar may start the plugin through a symlink; the rest of the tool lives next to the real file.
plugin_file=$0
[[ -L $plugin_file ]] && plugin_file=$(readlink "$plugin_file")
tool_dir=$(cd "$(dirname "$plugin_file")/.." && pwd)
watch="$tool_dir/bin/jenkins-watch"
# The notifier app also has the settings window.
settings_app="$tool_dir/notifier/Jenkins Watch.app"
config_dir="$tool_dir/config"
team_file="$config_dir/team.conf"
settings_file="$config_dir/settings"
cache_dir="$HOME/Library/Caches/jenkins-menubar"
jobs_file="$cache_dir/my-jobs"
jobs_user_file="$cache_dir/my-jobs-user"
rows_file="$cache_dir/rows"
state_file="$cache_dir/state"
hidden_file="$cache_dir/hidden"
error_file="$cache_dir/error"
last_poll_file="$cache_dir/last-poll"
gitlab_file="$cache_dir/gitlab.json"
gitlab_error_file="$cache_dir/gitlab-error"
last_gitlab_poll_file="$cache_dir/last-gitlab-poll"
work_items_file="$cache_dir/work-items.json"
work_items_error_file="$cache_dir/work-items-error"
work_item_labels_file="$cache_dir/work-item-labels.json"
related_dir="$cache_dir/related-merge-requests"
merged_file="$cache_dir/merged-merge-requests"
gitlab_icon_file="$tool_dir/icons/gitlab.png"
mkdir -p "$cache_dir" "${settings_file%/*}"
touch "$state_file" "$hidden_file" "$rows_file"
[[ -f $team_file ]] || cp "$config_dir/team.example.conf" "$team_file"

# Where Jenkins and GitLab live and the team's label conventions: config/team.conf, see config/team.example.conf.
team_value() {
	awk -v key="$1" 'index($0, key "=") == 1 { value = substr($0, length(key) + 2) } END { print value }' "$team_file" 2>/dev/null
}

JOB_ROOT=$(team_value jenkins_job_url)
JOB_ROOT=${JOB_ROOT%/}
GITLAB_URL=$(team_value gitlab_url)
GITLAB_URL=${GITLAB_URL%/}
GITLAB_PROJECT=$(team_value gitlab_project)
COMMITTED_LABEL=$(team_value committed_label)
SLOT_LABEL_PREFIX=$(team_value slot_label_prefix)
IGNORED_MR_PREFIX=$(team_value ignored_merge_request_prefix)

if [[ ! -f $settings_file ]]; then
	cat >"$settings_file" <<'EOF'
# Jenkins menubar settings. The menus change them; hand edits work too and apply within 30 seconds.
# A value goes right after the "=", comments need a line of their own.

# ── Jenkins builds ──
# Check Jenkins every N seconds.
refresh_seconds=60
# Hide finished builds after N hours, 0 = never, immediately = as soon as they finish.
hide_successful_after_hours=24
hide_failed_after_hours=168
# Hide the builds of merged MRs: on | off
hide_merged=on
# When a build finishes: dialog (a big alert) | banner, one or the other
alert=dialog
# Say the result out loud: on | off
voice=off
# Banner as soon as a stage fails: on | off
stage_alerts=on
# Build icons in the menubar: monochrome (like the system icons) | emoji (colored)
menubar_icons=monochrome

# ── GitLab ──
# Check GitLab (merge requests and work items) every N seconds.
gitlab_refresh_seconds=120

# ── GitLab work items ──
# assigned (to me) | authored (created by me)
work_items_scope=assigned
# all | ISSUE | TASK | EPIC | INCIDENT
work_items_type=all
# opened | closed | all
work_items_state=opened
# Labels a work item must have / must not have, comma-separated, e.g. workflow::done,type::bug
work_items_with_labels=
work_items_without_labels=
# Any GitLab issue sort, e.g. UPDATED_DESC | CREATED_DESC | CREATED_ASC | DUE_DATE_ASC | TITLE_ASC | WEIGHT_DESC | PRIORITY_ASC
work_items_sort=UPDATED_DESC
# How many not-committed work items to show, at most 100 (committed ones always show).
work_items_limit=20
EOF
fi

setting() {
	local value
	value=$(awk -v key="$1" 'index($0, key "=") == 1 { value = substr($0, length(key) + 2) } END { print value }' "$settings_file")
	printf '%s' "${value:-$2}"
}

number_setting() {
	local value
	value=$(setting "$1" "$2")
	[[ $value =~ ^[0-9]+$ ]] || value=$2
	printf '%s' "$value"
}

# The hours after which finished builds hide: a number, 0 for never or "immediately".
hide_setting() {
	local value
	value=$(setting "$1" "$2")
	[[ $value =~ ^[0-9]+$ || $value == immediately ]] || value=$2
	printf '%s' "$value"
}

# set_value <file> <key> <value>: replaces the key's line, or adds one.
set_value() {
	awk -v key="$2" -v value="$3" '
		index($0, key "=") == 1 { print key "=" value; found = 1; next }
		{ print }
		END { if (!found) print key "=" value }
	' "$1" >"$1.tmp" && mv "$1.tmp" "$1"
}

set_setting() {
	set_value "$settings_file" "$1" "$2"
}

watch_flags() {
	[[ $(setting voice off) == on ]] && printf -- '--voice '
	[[ $(setting alert dialog) == banner ]] && printf -- '--banner '
}

# Label lists are stored comma-separated; GitLab label names do not contain commas.
list_setting() {
	setting "$1" '' | tr ',' '\n' | grep -v '^$'
}

label_list() {
	list_setting "$1" | jq -R . | jq -sc .
}

# set_label_filter <label> <with | without | any>: puts the label in the "with" or the "without" list, or in neither; a
# label is never in both.
set_label_filter() {
	[[ $2 == with || $2 == without || $2 == any ]] || return 2
	local key
	for key in work_items_with_labels work_items_without_labels; do
		set_setting "$key" "$(list_setting "$key" | grep -vxF -- "$1" | paste -sd , -)"
	done
	[[ $2 == any ]] || set_setting "work_items_$2_labels" "$( (list_setting "work_items_$2_labels"; echo "$1") | paste -sd , -)"
}

# SwiftBar does not source ~/.zshrc, so a token comes from the environment, the login keychain (service jenkins-menubar,
# account the variable name) or a plain export in ~/.zshrc.
token() {
	local value=${!1:-}
	[[ -n $value ]] || value=$(security find-generic-password -s jenkins-menubar -a "$1" -w 2>/dev/null)
	[[ -n $value ]] || value=$(exported "$1")
	printf '%s' "$value"
}

# The value of the last "export NAME=value" in ~/.zshrc, quoted or not, with or without a comment after it. A computed
# value like $(security …) would need zsh to run it, so it is left out.
exported() {
	local value
	value=$(grep -E "^[[:space:]]*export $1=" "$HOME/.zshrc" 2>/dev/null | tail -n 1)
	value=${value#*=}
	case $value in
		\'*)
			value=${value#\'}
			printf '%s' "${value%%\'*}"
			return
			;;
		\"*) value=${value#\"}; value=${value%%\"*} ;;
		*) value=${value%%[[:space:]]*} ;;
	esac
	[[ $value == *'$'* || $value == *'`'* ]] || printf '%s' "$value"
}

# The token goes to curl through a file descriptor, so it does not show up in ps. Exits 22 when Jenkins answered with an
# HTTP error, with another code when it was not reached.
api() {
	curl -fsS --connect-timeout 5 --max-time 20 -H @<(printf 'Authorization: Basic %s\n' "$JENKINS_MCP_BASIC_AUTH") "$JOB_ROOT$1" 2>/dev/null
}

previous_state() {
	awk -F '\t' -v job="$1" '$1 == job' "$state_file"
}

stage_banner() {
	afplay /System/Library/Sounds/Basso.aiff &
	"$tool_dir/notifier/Jenkins Watch.app/Contents/MacOS/jenkins-notifier" --title "$1" --body "$2" --build "$3" --default build >/dev/null 2>&1 && return
	osascript - "$1" "$2" >/dev/null 2>&1 <<'APPLESCRIPT'
on run argv
	display notification (item 2 of argv) with title (item 1 of argv)
end run
APPLESCRIPT
}

# Asks Jenkins for the builds of my MRs, fires the alerts for builds that finished since the last poll, and caches the rows for render.
poll() {
	date +%s >"$last_poll_file"

	JENKINS_MCP_BASIC_AUTH=$(token JENKINS_MCP_BASIC_AUTH)
	export JENKINS_MCP_BASIC_AUTH
	if [[ -z $JENKINS_MCP_BASIC_AUTH ]]; then
		echo 'No Jenkins token: add it in Settings… → Accounts, or export JENKINS_MCP_BASIC_AUTH in ~/.zshrc' >"$error_file"
		return
	fi
	# MR jobs name the GitLab author as contributor; the Jenkins login stands in for the GitLab username until GitLab answered.
	local me offline=0
	me=$(jq -r '.data.currentUser.username // empty' "$gitlab_file" 2>/dev/null)
	[[ -n $me ]] || me=$(printf '%s' "$JENKINS_MCP_BASIC_AUTH" | base64 --decode 2>/dev/null | cut -d : -f 1)

	# Listing all MR jobs takes seconds, so the set of my jobs is refreshed less often than the builds.
	if [[ ! -f $jobs_file || -z $(find "$jobs_file" -mmin "-$DISCOVERY_MINUTES" 2>/dev/null) || $(cat "$jobs_user_file" 2>/dev/null) != "$me" ]]; then
		local discovered
		if discovered=$(api '/api/json?tree=jobs%5Bname,actions%5Bcontributor%5D%5D'); then
			jq -r --arg me "$me" '.jobs[] | select(any(.actions[]?; .contributor == $me)) | .name' <<<"$discovered" >"$jobs_file.tmp" &&
				mv "$jobs_file.tmp" "$jobs_file" && printf '%s\n' "$me" >"$jobs_user_file"
		else
			(($? == 22)) || offline=1
			if [[ ! -f $jobs_file ]]; then
				echo 'Jenkins unreachable (VPN?)' >"$error_file"
				return
			fi
		fi
	fi

	local new_state="$cache_dir/state.new" new_rows="$cache_dir/rows.new" reached=0 flags stage_alerts code
	local job json title mr_url number building result started_ms estimate_ms duration_ms stages failed_stages stages_json
	local previous previous_row previous_number previous_building previous_failed finished_failed build_url
	flags=$(watch_flags)
	stage_alerts=$(setting stage_alerts on)
	: >"$new_state"
	: >"$new_rows"
	while IFS= read -r job; do
		[[ -n $job ]] || continue
		previous=$(previous_state "$job")
		previous_row=$(awk -F '\t' -v job="$job" '$1 == job' "$rows_file")
		# Once Jenkins is not reached, every other job would only wait for its timeout too.
		code=1
		if ((!offline)); then
			json=$(api "/job/$job/api/json?tree=actions%5BobjectDisplayName,objectUrl%5D,lastBuild%5Bnumber,building,result,timestamp,estimatedDuration,duration%5D")
			code=$?
			((code == 0 || code == 22)) || offline=1
		fi
		if ((code != 0)); then
			# The build stays as it was, in the menu and hidden or not, until Jenkins answers for it again.
			[[ -n $previous ]] && printf '%s\n' "$previous" >>"$new_state"
			[[ -n $previous_row ]] && printf '%s\n' "$previous_row" >>"$new_rows"
			continue
		fi
		reached=1
		# No field may be empty: read merges neighbouring tabs and would shift the fields after it.
		IFS=$'\t' read -r title mr_url number building result started_ms estimate_ms duration_ms < <(jq -r '[
			([.actions[]? | .objectDisplayName // empty | select(. != "")][0] // "-"),
			([.actions[]? | .objectUrl // empty | select(. != "")][0] // "-"),
			(.lastBuild.number // 0),
			(.lastBuild.building // false),
			(.lastBuild.result // "NONE"),
			(.lastBuild.timestamp // 0),
			(.lastBuild.estimatedDuration // -1),
			(.lastBuild.duration // 0)
		] | @tsv' <<<"$json")
		[[ $number != 0 ]] || continue
		[[ $title != - ]] || title=$job

		previous_number='' previous_building='' previous_failed=''
		[[ -n $previous ]] && IFS=$'\t' read -r _ previous_number previous_building previous_failed <<<"$previous"
		[[ $previous_number == "$number" ]] || previous_failed=''

		stages=''
		failed_stages=''
		# The stages of a finished build do not change any more, so the last poll already knows its failed ones.
		if [[ $building == false ]] && finished_failed=$(awk -F '\t' -v number="$number" '
			$4 == number && $5 == "false" { print $11; found = 1 } END { exit !found }' <<<"$previous_row"); then
			[[ $finished_failed == - ]] || failed_stages=$finished_failed
		elif [[ $building == true || $result == FAILURE || $result == UNSTABLE ]]; then
			if stages_json=$(api "/job/$job/$number/wfapi/describe"); then
				stages=$(jq -r '[.stages[]? | select(.status == "IN_PROGRESS") | .name] | join(", ")' <<<"$stages_json")
				failed_stages=$(jq -r '[.stages[]? | select(.status == "FAILED") | .name] | join(", ")' <<<"$stages_json")
			else
				# Unknown this time: the last known ones keep a stage that failed before from getting a second banner.
				failed_stages=$previous_failed
			fi
		fi

		build_url="$JOB_ROOT/job/$job/$number/"
		if [[ -n $previous ]]; then
			if [[ $previous_number == "$number" && $previous_building == true && $building == false ]]; then
				nohup "$watch" $flags "$build_url" </dev/null >/dev/null 2>&1 &
			fi
			if [[ $stage_alerts == on && $building == true && -n $failed_stages && $failed_stages != "$previous_failed" ]]; then
				stage_banner "💥 !${job#MR-} #$number: stage failed" "$failed_stages"$'\n'"$title" "$build_url"
			fi
		fi
		printf '%s\t%s\t%s\t%s\n' "$job" "$number" "$building" "$failed_stages" >>"$new_state"
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$job" "${title//$'\t'/ }" "$mr_url" "$number" "$building" "$result" \
			"$started_ms" "$estimate_ms" "$duration_ms" "${stages:--}" "${failed_stages:--}" >>"$new_rows"
	done <"$jobs_file"
	mv "$new_state" "$state_file"

	if ((!reached)) && [[ -s $jobs_file ]]; then
		rm -f "$new_rows"
		echo 'Jenkins unreachable (VPN?)' >"$error_file"
		return
	fi
	sort -t $'\t' -k 7,7nr "$new_rows" >"$rows_file"
	rm -f "$new_rows" "$error_file"
	((offline)) && echo 'Jenkins unreachable (VPN?)' >"$error_file"

	# A hidden build only stays hidden until the next build of that MR starts.
	awk -F '\t' 'NR == FNR { current[$1 "\t" $4]; next } ($1 "\t" $2) in current' "$rows_file" "$hidden_file" >"$hidden_file.tmp"
	mv "$hidden_file.tmp" "$hidden_file"
}

read -r -d '' GITLAB_QUERY <<'GRAPHQL'
fragment item on MergeRequest {
  iid
  title
  webUrl
  draft
  reference(full: true)
  updatedAt
  detailedMergeStatus
  author { username name }
  headPipeline { status }
  diffStatsSummary { additions deletions fileCount }
  reviewers { nodes { username mergeRequestInteraction { reviewState approved } } }
}

query {
  currentUser {
    username
    authored: authoredMergeRequests(state: opened, first: 50) { nodes { ...item } }
    assigned: assignedMergeRequests(state: opened, first: 50) { nodes { ...item } }
    reviewing: reviewRequestedMergeRequests(state: opened, first: 50) { nodes { ...item } }
  }
}
GRAPHQL

# Turns the GraphQL answer into the "GitLab merge requests" submenu, with the sections of the GitLab dashboard.
read -r -d '' GITLAB_MENU <<'JQ'
def ago: (now - .) as $seconds
	| if $seconds < 3600 then "\($seconds / 60 | floor)m ago"
	elif $seconds < 86400 then "\($seconds / 3600 | floor)h ago"
	else "\($seconds / 86400 | floor)d ago" end;
def updated: try ("updated " + (sub("\\.[0-9]+"; "") | fromdateiso8601 | ago)) catch "";
def shorten($max): if length > $max then .[0:$max - 1] + "…" else . end;
def count($noun): "\(.) \($noun)\(if . == 1 then "" else "s" end)";
def clean: gsub("\\|"; "¦");
def ref: capture("^(?<path>.*)!(?<iid>[0-9]+)$") as $reference
	| if $reference.path == $project then "!\($reference.iid)" else "\($reference.path | split("/") | last)!\($reference.iid)" end;
def reviewState($me): [.reviewers.nodes[]? | select(.username == $me) | .mergeRequestInteraction.reviewState][0] // "UNREVIEWED";
# Counted over the reviewers, not GitLab's approval rules, which add every code owner rule up.
def approvals:
	[.reviewers.nodes[]?.mergeRequestInteraction.approved] as $reviewers
	| ($reviewers | map(select(. | not)) | length) as $missing
	| if ($reviewers | length) == 0 then "No reviewers yet"
	elif $missing == 0 then "All reviewers approved, approval rules still open"
	else "Missing \($missing) of \($reviewers | length | count("approval"))" end;
def status:
	if .detailedMergeStatus == "MERGEABLE" then "Ready to merge"
	elif .draft then "Draft"
	elif .headPipeline.status == "FAILED" then "Pipeline failed"
	elif .detailedMergeStatus == "CONFLICT" then "Merge conflicts"
	elif .detailedMergeStatus == "NEED_REBASE" then "Needs a rebase"
	elif .detailedMergeStatus == "REQUESTED_CHANGES" then "Changes requested"
	elif .detailedMergeStatus == "NOT_APPROVED" then approvals
	elif .detailedMergeStatus == "DISCUSSIONS_NOT_RESOLVED" then "Unresolved threads"
	elif .detailedMergeStatus == "CI_STILL_RUNNING" then "Pipeline running"
	elif .detailedMergeStatus | IN("UNCHECKED", "CHECKING", "PREPARING", "APPROVALS_SYNCING") then "Checking mergeability"
	else (.detailedMergeStatus // "unknown" | ascii_downcase | gsub("_"; " ")) end;
def details($me; $state):
	[(.reference | ref), $state, (if .author.username != $me then "by \(.author.name)" else empty end), (.updatedAt | updated),
		"\(.diffStatsSummary.fileCount // 0 | count("file")) +\(.diffStatsSummary.additions // 0) −\(.diffStatsSummary.deletions // 0)",
		(if .headPipeline.status then "pipeline \(.headPipeline.status | ascii_downcase)" else empty end)]
	| map(select(. != "")) | join(" · ") | clean | gsub("\""; "'");
def entry($me; $requested):
	(if $requested then "Review requested · \(status)" else status end) as $state
	| "--\(.title | clean | shorten(60)) | href=\(.webUrl) tooltip=\"\(details($me; $state))\"";
def section($title; $items; $me; $requested):
	if ($items | length) > 0
	then ["--\($title) | size=12 color=#8E8E93"] + [$items | sort_by(.updatedAt) | reverse | .[] | entry($me; $requested)]
	else empty end;

.data.currentUser as $user
| $user.username as $me
| ($user.reviewing.nodes | map(select(reviewState($me) | IN("UNREVIEWED", "REVIEW_STARTED", "UNAPPROVED")))) as $requested
| [$requested[].webUrl] as $requestedUrls
| ($user.authored.nodes + $user.assigned.nodes | unique_by(.webUrl) | map(select(.webUrl | IN($requestedUrls[]) | not))) as $mine
| ([$mine[].webUrl] + $requestedUrls) as $shownUrls
| ($user.reviewing.nodes | map(select(.webUrl | IN($shownUrls[]) | not))) as $reviewed
| [section("Your merge requests"; $mine; $me; false), section("Review requested"; $requested; $me; true), section("Reviewed"; $reviewed; $me; false)] as $sections
| ([(if ($mine | length) > 0 then "\($mine | length) open" else empty end), (if ($requested | length) > 0 then "\($requested | length) to review" else empty end)]) as $counts
| "GitLab merge requests\(if ($counts | length) > 0 then " · " + ($counts | join(" · ")) else "" end)\($icon)",
	(if ($sections | length) > 0 then $sections | map(. + ["-----"]) | add | .[] else "--No open merge requests | color=#8E8E93", "-----" end),
	"--All merge requests in GitLab | href=\($dashboard)",
	"--Last checked \($checked) | size=12 color=#8E8E93"
JQ

# Committed work items are fetched apart from the others, so the sort and the limit can never push them out of the menu.
read -r -d '' WORK_ITEMS_QUERY <<'GRAPHQL'
fragment item on Issue {
  title
  webUrl
  reference(full: true)
  updatedAt
  labels(first: 30) { nodes { title } }
}

query($assignee: [String!], $author: String, $types: [IssueType!], $state: IssuableState, $sort: IssueSort,
      $withCommitted: Boolean!, $committedLabels: [String], $committedNot: NegatedIssueFilterInput,
      $withOthers: Boolean!, $otherLabels: [String], $otherNot: NegatedIssueFilterInput, $first: Int) {
  committed: issues(assigneeUsernames: $assignee, authorUsername: $author, types: $types, state: $state,
      labelName: $committedLabels, not: $committedNot, sort: $sort, first: 50) @include(if: $withCommitted) {
    count
    nodes { ...item }
  }
  others: issues(assigneeUsernames: $assignee, authorUsername: $author, types: $types, state: $state,
      labelName: $otherLabels, not: $otherNot, sort: $sort, first: $first) @include(if: $withOthers) {
    count
    nodes { ...item }
  }
}
GRAPHQL

# Turns the work items answer (or null) into the "GitLab work items" submenu, including the filter and sort controls.
read -r -d '' WORK_ITEMS_MENU <<'JQ'
def shorten($max): if length > $max then .[0:$max - 1] + "…" else . end;
def clean: gsub("\\|"; "¦");
def shortRef: capture("^(?<path>.*?)(?<sign>[#&])(?<iid>[0-9]+)$") as $reference
	| if $reference.path == $project then "\($reference.sign)\($reference.iid)"
	else "\($reference.path | split("/") | last)\($reference.sign)\($reference.iid)" end;
def countText: if .count > (.nodes | length) then "\(.nodes | length) of \(.count)" else "\(.count)" end;
def slot: if $slotPrefix == "" then null else [.labels.nodes[].title | select(startswith($slotPrefix)) | ltrimstr($slotPrefix)][0] end;
def mergeRequestMark($mergeRequests):
	if any($mergeRequests[]; .state == "opened") then "🔀" elif any($mergeRequests[]; .state == "merged") then "🏁" else empty end;
def valueOf: if test("::") then split("::")[1:] | join("::") elif test(":") then split(":")[1:] | join(":") else . end;
def named($options; $value): [$options[] | select(.[0] == $value) | .[1]][0] // $value;
# The filters in one line; the settings window changes them.
def filters:
	[named([["assigned", "Assigned to me"], ["authored", "Created by me"]]; $scope),
		(if $type == "all" then empty else named([["ISSUE", "Issues"], ["TASK", "Tasks"], ["EPIC", "Epics"], ["INCIDENT", "Incidents"]]; $type) end),
		named([["opened", "Open"], ["closed", "Closed"], ["all", "Open and closed"]]; $state),
		($with[] | "+" + valueOf), ($without[] | "−" + valueOf)]
	| join(" · ") | clean;
def entry:
	# Automatic MRs (like cascades between release branches) only mention the work item, they are not work on it.
	[$related[.reference].mergeRequests[]? | select((.state == "opened" or .state == "merged")
		and ($ignoredPrefix == "" or (.title | startswith($ignoredPrefix) | not)))] as $mergeRequests
	| ([slot // empty, mergeRequestMark($mergeRequests)] | join(" ")) as $prefix
	| "--\(.reference | shortRef)  \(if $prefix != "" then "\($prefix) · " else "" end)\(.title | clean | shorten(if $prefix != "" then 52 else 60 end)) | href=\(.webUrl)";
def section($title):
	if . != null and (.nodes | length) > 0
	then "--\($title) (\(countText)) | size=12 color=#8E8E93", (.nodes[] | entry), "-----"
	else empty end;

($result.data // null) as $data
| ($data.committed // null) as $committedItems
| ($data.others // null) as $otherItems
| "GitLab work items\(if $data == null then "" elif ($committedItems.count // 0) > 0 then " · \($committedItems.count) committed" else " (\($otherItems // {count: 0, nodes: []} | countText))" end)\(if $problem != "" then " ⚠️" else "" end)\($icon)",
	(if $problem != "" then "--\($problem | clean) | color=red" else empty end),
	($committedItems | section("🟣 Committed")),
	($otherItems | section(if $committedLabel == "" then "Work items" else "Not committed" end)),
	(if $data != null and ([$committedItems, $otherItems] | map(.nodes // [] | length) | add) == 0
		then "--No work items match the filter | color=#8E8E93", "-----" else empty end),
	(if $data == null then "-----" else empty end),
	"--\(filters) | size=12 color=#8E8E93",
	"--Filters… | \($filtersAction)",
	"-----",
	"--All work items in GitLab | href=\($base)/dashboard/issues?\(if $scope == "authored" then "author_username" else "assignee_username" end)=\($me)&state=\($state)",
	(if $checked != "" then "--Last checked \($checked) | size=12 color=#8E8E93" else empty end)
JQ

# Writes the response body to $3 and prints the HTTP status (000 when GitLab was not reached). The token goes to curl
# through a file descriptor, so it does not show up in ps.
gitlab_request() {
	curl -sS --connect-timeout 5 --max-time 30 -o "$3" -w '%{http_code}' -H @<(printf 'Authorization: Bearer %s\n' "$GITLAB_TOKEN") \
		-H 'Content-Type: application/json' \
		-d "$(jq -n --arg query "$1" --argjson variables "$2" '{query: $query, variables: $variables}')" "$GITLAB_URL/api/graphql" 2>/dev/null
}

work_items_variables() {
	jq -n --arg me "$1" --arg scope "$(setting work_items_scope assigned)" --arg type "$(setting work_items_type all)" \
		--arg state "$(setting work_items_state opened)" --argjson with "$(label_list work_items_with_labels)" \
		--argjson without "$(label_list work_items_without_labels)" \
		--arg sort "$(setting work_items_sort UPDATED_DESC)" --argjson first "$(number_setting work_items_limit 20)" \
		--arg committed "$COMMITTED_LABEL" '{
		assignee: (if $scope == "authored" then null else [$me] end),
		author: (if $scope == "authored" then $me else null end),
		types: (if $type == "all" then null else [$type] end),
		state: $state,
		sort: $sort,
		withCommitted: ($committed != "" and ($committed | IN($without[]) | not)),
		committedLabels: ($with + [$committed] | unique),
		committedNot: (if ($without | length) > 0 then {labelName: $without} else null end),
		withOthers: ($committed == "" or ($committed | IN($with[]) | not)),
		otherLabels: (if ($with | length) > 0 then $with else null end),
		otherNot: (($without + [$committed] | map(select(. != "")) | unique) as $not
			| if ($not | length) > 0 then {labelName: $not} else null end),
		first: $first
	}'
}

read -r -d '' RELATED_QUERY <<'GRAPHQL'
query($path: ID!, $iid: String!) {
  project(fullPath: $path) {
    issue(iid: $iid) {
      relatedMergeRequests(first: 10) { nodes { iid state title webUrl reference(full: true) } }
    }
  }
}
GRAPHQL

fetch_related_merge_requests() {
	local reference=$1 updated=$2 file=$3
	gitlab_request "$RELATED_QUERY" "$(jq -n --arg path "${reference%#*}" --arg iid "${reference##*#}" '{path: $path, iid: $iid}')" "$file.new" >/dev/null
	if jq -e '.data.project.issue' "$file.new" >/dev/null 2>&1; then
		jq --arg reference "$reference" --arg updated "$updated" \
			'{reference: $reference, updatedAt: $updated, mergeRequests: .data.project.issue.relatedMergeRequests.nodes}' "$file.new" >"$file"
	fi
	rm -f "$file.new"
}

# GitLab resolves relatedMergeRequests for one work item per request only, so each item is asked separately, a few in
# parallel, and its answer is reused until the item changes or ten minutes have passed (an MR can be merged meanwhile).
refresh_related_merge_requests() {
	mkdir -p "$related_dir"
	find "$related_dir" -name '*.json' -mtime +1 -delete 2>/dev/null
	local reference updated file started=0
	while IFS=$'\t' read -r reference updated; do
		file="$related_dir/$(printf '%s' "$reference" | tr '/#' '__').json"
		if [[ -s $file && $(jq -r '.updatedAt' "$file") == "$updated" && -n $(find "$file" -mmin -10) ]]; then
			continue
		fi
		fetch_related_merge_requests "$reference" "$updated" "$file" &
		started=$((started + 1))
		((started % 6 == 0)) && wait
	done < <(jq -r '.data[]?.nodes[]? | select(.reference | test("#[0-9]+$")) | [.reference, .updatedAt] | @tsv' "$work_items_file")
	wait
}

read -r -d '' MERGED_QUERY <<'GRAPHQL'
query($path: ID!, $iids: [String!]) {
  project(fullPath: $path) { mergeRequests(iids: $iids, state: merged) { nodes { iid } } }
}
GRAPHQL

# Remembers which MRs in the Jenkins menu are merged, for "Hide builds of merged MRs".
refresh_merged_merge_requests() {
	local iids
	iids=$(awk -F '\t' '{ sub(/^MR-/, "", $1); print $1 }' "$rows_file" | jq -Rsc 'split("\n") | map(select(test("^[0-9]+$")))')
	if [[ $iids == '[]' ]]; then
		: >"$merged_file"
		return
	fi
	gitlab_request "$MERGED_QUERY" "$(jq -n --arg path "$GITLAB_PROJECT" --argjson iids "$iids" '{path: $path, iids: $iids}')" "$merged_file.new" >/dev/null
	if jq -e '.data.project' "$merged_file.new" >/dev/null 2>&1; then
		jq -r '.data.project.mergeRequests.nodes[].iid' "$merged_file.new" >"$merged_file"
	fi
	rm -f "$merged_file.new"
}

poll_gitlab() {
	date +%s >"$last_gitlab_poll_file"
	GITLAB_TOKEN=$(token GITLAB_TOKEN)
	if [[ -z $GITLAB_TOKEN ]]; then
		rm -f "$gitlab_file" "$gitlab_error_file" "$work_items_file" "$work_items_error_file"
		return
	fi

	local status
	status=$(gitlab_request "$GITLAB_QUERY" '{}' "$gitlab_file.new")
	if [[ $status == 200 ]] && jq -e '.data.currentUser' "$gitlab_file.new" >/dev/null 2>&1; then
		mv "$gitlab_file.new" "$gitlab_file"
		rm -f "$gitlab_error_file"
		refresh_merged_merge_requests
	else
		rm -f "$gitlab_file.new"
		# 403 is a token without the read_api scope.
		if [[ $status == 401 || $status == 403 || $status == 200 ]]; then
			echo 'GitLab rejected the token (expired, or without the read_api scope?)' >"$gitlab_error_file"
		else
			echo "GitLab unreachable (HTTP $status)" >"$gitlab_error_file"
		fi
		return
	fi

	status=$(gitlab_request "$WORK_ITEMS_QUERY" "$(work_items_variables "$(jq -r '.data.currentUser.username' "$gitlab_file")")" "$work_items_file.new")
	if [[ $status == 200 ]] && jq -e '.data and (.errors | not)' "$work_items_file.new" >/dev/null 2>&1; then
		mv "$work_items_file.new" "$work_items_file"
		rm -f "$work_items_error_file"
		refresh_related_merge_requests
		# Collects the labels offered by the label filters, with when a work item last had each, so labels unseen for 30 days
		# drop out again; an answer filtered to a label only contains its co-labels. The list used to be a plain array.
		if [[ -z $(setting work_items_with_labels '') ]]; then
			[[ -s $work_item_labels_file ]] || echo '{}' >"$work_item_labels_file"
			jq -s 'def seen: map({key: ., value: now | floor}) | from_entries;
				(.[0] | if type == "array" then seen else . end) + ([.[1].data[]?.nodes[]?.labels.nodes[].title] | seen)
				| with_entries(select(.value > now - 30 * 86400))' "$work_item_labels_file" "$work_items_file" >"$work_item_labels_file.new" &&
				mv "$work_item_labels_file.new" "$work_item_labels_file"
		fi
	else
		jq -r '.errors[0].message // empty' "$work_items_file.new" 2>/dev/null | head -n 1 >"$work_items_error_file"
		[[ -s $work_items_error_file ]] || echo "Work items request failed (HTTP $status)" >"$work_items_error_file"
		rm -f "$work_items_file.new"
	fi
}

# The GitLab logo as SwiftBar item parameter; 32px saved at 144 DPI, so it draws at 16pt like the menu text.
gitlab_icon() {
	[[ -s $gitlab_icon_file ]] && printf ' | image=%s' "$(base64 <"$gitlab_icon_file" | tr -d '\n')"
}

render_work_items() {
	if [[ ! -s $gitlab_file && ! -s $work_items_file ]]; then
		echo "GitLab work items$(gitlab_icon)"
		echo '--Needs the GitLab token, see GitLab merge requests | color=#8E8E93'
		return
	fi
	local result=null checked=''
	[[ -s $work_items_file ]] && result=$(cat "$work_items_file")
	[[ -s $last_gitlab_poll_file ]] && checked=$(date -r "$(cat "$last_gitlab_poll_file")" +%H:%M)
	jq -nr --argjson result "$result" --arg problem "$(cat "$work_items_error_file" 2>/dev/null)" \
		--arg project "$GITLAB_PROJECT" --arg base "$GITLAB_URL" --arg me "$(jq -r '.data.currentUser.username // empty' "$gitlab_file" 2>/dev/null)" \
		--arg scope "$(setting work_items_scope assigned)" --arg type "$(setting work_items_type all)" \
		--arg state "$(setting work_items_state opened)" --argjson with "$(label_list work_items_with_labels)" \
		--argjson without "$(label_list work_items_without_labels)" \
		--argjson related "$(cat "$related_dir"/*.json 2>/dev/null | jq -sc 'map({key: .reference, value: .}) | from_entries')" \
		--arg checked "$checked" --arg icon "$(gitlab_icon)" --arg filtersAction "$(settings_action gitlab)" \
		--arg slotPrefix "$SLOT_LABEL_PREFIX" --arg ignoredPrefix "$IGNORED_MR_PREFIX" --arg committedLabel "$COMMITTED_LABEL" "$WORK_ITEMS_MENU"
}

render_gitlab() {
	if [[ -s $gitlab_file ]]; then
		jq -r --arg project "$GITLAB_PROJECT" --arg dashboard "$GITLAB_URL/dashboard/merge_requests" \
			--arg checked "$(date -r "$(cat "$last_gitlab_poll_file")" +%H:%M)" --arg icon "$(gitlab_icon)" "$GITLAB_MENU" "$gitlab_file"
		[[ -s $gitlab_error_file ]] && echo "--⚠️ $(cat "$gitlab_error_file") | color=red"
	elif [[ -s $gitlab_error_file ]]; then
		echo "GitLab merge requests ⚠️$(gitlab_icon)"
		echo "--$(cat "$gitlab_error_file") | color=red"
		echo "--Check now | bash=\"$self\" param1=--check-now terminal=false refresh=true"
	else
		echo "GitLab merge requests$(gitlab_icon)"
		echo '--Needs a GitLab token with the read_api scope | color=#8E8E93'
		echo "--1. Create the token in GitLab | href=$GITLAB_URL/-/user_settings/personal_access_tokens?name=Jenkins%20menubar&scopes=read_api"
		if has_settings_app; then
			echo "--2. Paste it in Settings… → Accounts | $(settings_action accounts)"
		else
			echo '--2. Add  export GITLAB_TOKEN=<the token>  to ~/.zshrc, or put it in the keychain (README) | color=#8E8E93'
		fi
		echo "--3. Check now | bash=\"$self\" param1=--check-now terminal=false refresh=true"
	fi
}

format_duration() {
	printf '%dh%02dm' $(($1 / 3600)) $(($1 % 3600 / 60))
}

ago() {
	if (($1 < 3600)); then
		printf '%dm ago' $(($1 / 60))
	elif (($1 < 86400)); then
		printf '%dh ago' $(($1 / 3600))
	else
		printf '%dd ago' $(($1 / 86400))
	fi
}

has_settings_app() {
	[[ -x $settings_app/Contents/MacOS/jenkins-notifier ]]
}

# settings_action <pane>: the SwiftBar parameters of a menu item that opens the settings window at the pane (jenkins,
# gitlab, accounts or team); without the app, which install.sh builds, the settings file in a text editor.
settings_action() {
	if has_settings_app; then
		printf 'bash=/usr/bin/open param1=-n param2="%s" param3=--args param4=--settings param5=%s terminal=false' "$settings_app" "$1"
	else
		printf 'bash=/usr/bin/open param1=-t param2="%s" terminal=false' "$settings_file"
	fi
}

render() {
	local now hide_successful hide_failed hide_after hide_merged running=0 failed=0 unstable=0 green=0 hidden_count=0 menu='' summary=''
	local job title mr_url number building result started_ms estimate_ms duration_ms stages failed_stages
	local mr build_url icon label detail elapsed left finished_age last_poll
	now=$(date +%s)
	hide_successful=$(hide_setting hide_successful_after_hours 24)
	hide_failed=$(hide_setting hide_failed_after_hours 168)
	hide_merged=$(setting hide_merged on)

	while IFS=$'\t' read -r job title mr_url number building result started_ms estimate_ms duration_ms stages failed_stages; do
		[[ -n $job ]] || continue
		[[ $hide_merged == on ]] && grep -qxF "${job#MR-}" "$merged_file" 2>/dev/null && continue
		if [[ $building != true ]]; then
			finished_age=$((now - (started_ms + duration_ms) / 1000))
			hide_after=$hide_failed
			[[ $result == SUCCESS ]] && hide_after=$hide_successful
			[[ $hide_after == immediately ]] && continue
			((hide_after > 0 && finished_age > hide_after * 3600)) && continue
		fi
		if grep -qxF "$job"$'\t'"$number" "$hidden_file"; then
			hidden_count=$((hidden_count + 1))
			continue
		fi
		[[ $stages != - ]] || stages=''
		[[ $failed_stages != - ]] || failed_stages=''
		mr=${job#MR-}
		build_url="$JOB_ROOT/job/$job/$number/"

		if [[ $building == true ]]; then
			icon='⏳'
			running=$((running + 1))
			elapsed=$((now - started_ms / 1000))
			detail="$(format_duration $elapsed) elapsed"
			if ((estimate_ms > 0)); then
				left=$((estimate_ms / 1000 - elapsed))
				((left < 0)) && left=0
				detail="$detail · ~$(format_duration $left) left"
			fi
			[[ -n $stages ]] && detail="▶ $stages · $detail"
		else
			case $result in
				SUCCESS) icon='✅'; green=$((green + 1)) ;;
				UNSTABLE) icon='⚠️'; unstable=$((unstable + 1)) ;;
				FAILURE) icon='❌'; failed=$((failed + 1)) ;;
				ABORTED) icon='⏹' ;;
				*) icon='❔' ;;
			esac
			detail="$result · $(format_duration $((duration_ms / 1000))) · finished $(ago $finished_age)"
			[[ -n $failed_stages ]] && detail="$detail · failed: $failed_stages"
		fi

		# Truncated here rather than with SwiftBar's length=, which adds a tooltip that covers the submenu.
		label="$icon ${title//|/¦}"
		((${#label} > 70)) && label="${label:0:69}…"
		menu+="$label"$'\n'
		menu+="--${detail//|/¦} | color=#8E8E93 href=$build_url"$'\n'
		menu+="-----"$'\n'
		[[ $mr_url != - ]] && menu+="--🦊 Open merge request !$mr in GitLab | href=$mr_url"$'\n'
		menu+="--👷‍♂️ Open build #$number | href=$build_url"$'\n'
		menu+="--📜 Console output | href=${build_url}console"$'\n'
		menu+="--🧪 Test results | href=${build_url}testReport"$'\n'
		menu+="-----"$'\n'
		menu+="--🙈 Hide from menu until the next build | bash=\"$self\" param1=--hide param2=$job param3=$number terminal=false refresh=true"$'\n'
	done <"$rows_file"

	# SF Symbols keep the menubar monochrome like the system icons next to it.
	local running_icon=':hourglass:' failed_icon=':xmark.circle.fill:' unstable_icon=':exclamationmark.triangle:'
	local green_icon=':checkmark.circle:' error_icon=':exclamationmark.circle:'
	if [[ $(setting menubar_icons monochrome) == emoji ]]; then
		running_icon='⏳' failed_icon='❌' unstable_icon='⚠️' green_icon='✅' error_icon='⚠️'
	fi
	((running)) && summary+="$running_icon$running "
	((failed)) && summary+="$failed_icon$failed "
	((unstable)) && summary+="$unstable_icon$unstable "
	((green)) && summary+="$green_icon$green "
	summary=${summary% }
	[[ -s $error_file ]] && summary="$error_icon $summary"
	# emojize=false, or SwiftBar reads :hourglass: as the GitHub emoji shortcode instead of the symbol.
	echo "${summary:-CI} | emojize=false"

	echo '---'
	[[ -s $error_file ]] && echo "$(cat "$error_file") | color=red"
	if [[ -n $menu ]]; then
		printf '%s' "$menu"
	elif [[ ! -s $jobs_file && -s $jobs_user_file ]]; then
		# Names the user the jobs were looked up for, which helps when the Jenkins and the GitLab username differ.
		echo "No merge request builds by $(cat "$jobs_user_file") in Jenkins | color=#8E8E93"
	else
		echo 'No builds to show | color=#8E8E93'
	fi

	echo '---'
	render_gitlab
	render_work_items

	echo '---'
	((hidden_count == 1)) && echo "Show 1 hidden build | bash=\"$self\" param1=--unhide-all terminal=false refresh=true"
	((hidden_count > 1)) && echo "Show $hidden_count hidden builds | bash=\"$self\" param1=--unhide-all terminal=false refresh=true"
	last_poll=$(cat "$last_poll_file" 2>/dev/null)
	echo "Check now${last_poll:+ (last checked $(date -r "$last_poll" +%H:%M))} | bash=\"$self\" param1=--check-now terminal=false refresh=true"
	echo "All builds in Jenkins | href=$JOB_ROOT"
	echo "Settings… | $(settings_action jenkins)"
}

# ── For the settings window (notifier/SettingsModel.swift), which keeps no logic of its own ──

# Where token() finds the token: environment, keychain, zshrc, zshrc-computed (an export the menu cannot run) or none.
token_source() {
	if [[ -n ${!1:-} ]]; then
		echo environment
	elif security find-generic-password -s jenkins-menubar -a "$1" >/dev/null 2>&1; then
		echo keychain
	elif [[ -n $(exported "$1") ]]; then
		echo zshrc
	elif grep -qE "^[[:space:]]*export $1=" "$HOME/.zshrc" 2>/dev/null; then
		echo zshrc-computed
	else
		echo none
	fi
}

# Everything the settings window shows, as JSON: the settings with their defaults applied, the team configuration, the
# labels the label filters offer, where the tokens come from, the files and the pages to get tokens from.
settings_json() {
	local pair key value known='[]'
	[[ -s $work_item_labels_file ]] && known=$(jq -c 'if type == "array" then . else keys end' "$work_item_labels_file" 2>/dev/null || echo '[]')
	jq -n --argjson settings "$(
		for pair in refresh_seconds=60 hide_successful_after_hours=24 hide_failed_after_hours=168 hide_merged=on alert=dialog \
			voice=off stage_alerts=on menubar_icons=monochrome gitlab_refresh_seconds=120 work_items_scope=assigned \
			work_items_type=all work_items_state=opened work_items_with_labels= work_items_without_labels= \
			work_items_sort=UPDATED_DESC work_items_limit=20; do
			key=${pair%%=*}
			if [[ $key == hide_*_after_hours ]]; then
				value=$(hide_setting "$key" "${pair#*=}")
			elif [[ ${pair#*=} =~ ^[0-9]+$ ]]; then
				value=$(number_setting "$key" "${pair#*=}")
			else
				value=$(setting "$key" "${pair#*=}")
			fi
			printf '%s\t%s\n' "$key" "$value"
		done | jq -Rn '[inputs | split("\t") | {key: .[0], value: (.[1] // "")}] | from_entries'
	)" --argjson team "$(
		for key in jenkins_job_url gitlab_url gitlab_project committed_label slot_label_prefix ignored_merge_request_prefix; do
			printf '%s\t%s\n' "$key" "$(team_value "$key")"
		done | jq -Rn '[inputs | split("\t") | {key: .[0], value: (.[1] // "")}] | from_entries'
	)" --argjson known "$known" --argjson with "$(label_list work_items_with_labels)" \
		--argjson without "$(label_list work_items_without_labels)" \
		--arg jenkinsSource "$(token_source JENKINS_MCP_BASIC_AUTH)" \
		--arg jenkinsUser "$(token JENKINS_MCP_BASIC_AUTH | base64 --decode 2>/dev/null | cut -d : -f 1)" \
		--arg gitlabSource "$(token_source GITLAB_TOKEN)" --arg settingsFile "$settings_file" --arg teamFile "$team_file" \
		--arg jenkinsRoot "${JOB_ROOT%%/job/*}" --arg gitlabUrl "$GITLAB_URL" '{
		settings: $settings,
		team: $team,
		labels: ($known + $with + $without | unique),
		tokens: {jenkins: {source: $jenkinsSource, user: $jenkinsUser}, gitlab: {source: $gitlabSource, user: ""}},
		files: {settings: $settingsFile, team: $teamFile},
		links: {
			jenkinsToken: (if $jenkinsRoot == "" then null else "\($jenkinsRoot)/me/" end),
			gitlabToken: (if $gitlabUrl == "" then null
				else "\($gitlabUrl)/-/user_settings/personal_access_tokens?name=Jenkins%20menubar&scopes=read_api" end)
		}
	}'
}

# store_token <JENKINS_MCP_BASIC_AUTH | GITLAB_TOKEN>: puts the token read from stdin in the keychain. security reads its
# command from stdin too, so the token never shows up in ps.
store_token() {
	local value token_pattern='^[A-Za-z0-9+/=._~-]+$'
	value=$(cat)
	[[ $1 == JENKINS_MCP_BASIC_AUTH || $1 == GITLAB_TOKEN ]] || { echo "unknown token $1" >&2; return 2; }
	[[ $value =~ $token_pattern ]] || { echo 'That does not look like a token: it has spaces or quotes' >&2; return 2; }
	printf 'add-generic-password -U -s jenkins-menubar -a %s -w "%s"\n' "$1" "$value" | security -i >/dev/null 2>&1
	security find-generic-password -s jenkins-menubar -a "$1" >/dev/null 2>&1 || { echo 'The keychain did not take the token' >&2; return 1; }
	# Jenkins and GitLab are asked again with the new token right away.
	rm -f "$last_poll_file" "$last_gitlab_poll_file"
}

delete_token() {
	[[ $1 == JENKINS_MCP_BASIC_AUTH || $1 == GITLAB_TOKEN ]] || { echo "unknown token $1" >&2; return 2; }
	security delete-generic-password -s jenkins-menubar -a "$1" >/dev/null 2>&1
	rm -f "$last_poll_file" "$last_gitlab_poll_file"
}

# Asks Jenkins and GitLab with the tokens the menu uses: JSON with ok and a message for each.
check_accounts() {
	local jenkins_ok=false jenkins_message gitlab_ok=false gitlab_message status username answer="$cache_dir/check-accounts.json"
	JENKINS_MCP_BASIC_AUTH=$(token JENKINS_MCP_BASIC_AUTH)
	GITLAB_TOKEN=$(token GITLAB_TOKEN)
	if [[ -z $JOB_ROOT ]]; then
		jenkins_message='Set the Jenkins job in Team first'
	elif [[ -z $JENKINS_MCP_BASIC_AUTH ]]; then
		jenkins_message='No token yet'
	else
		status=$(curl -sS --connect-timeout 5 --max-time 20 -o /dev/null -w '%{http_code}' \
			-H @<(printf 'Authorization: Basic %s\n' "$JENKINS_MCP_BASIC_AUTH") "$JOB_ROOT/api/json?tree=name" 2>/dev/null)
		case $status in
			200)
				jenkins_ok=true
				jenkins_message="Signed in as $(printf '%s' "$JENKINS_MCP_BASIC_AUTH" | base64 --decode 2>/dev/null | cut -d : -f 1)"
				;;
			401 | 403) jenkins_message='Jenkins rejected the token' ;;
			404) jenkins_message='Jenkins does not know the job: check the job URL in Team' ;;
			000) jenkins_message='Jenkins unreachable (VPN?)' ;;
			*) jenkins_message="Jenkins answered with HTTP $status" ;;
		esac
	fi
	if [[ -z $GITLAB_URL ]]; then
		gitlab_message='Set the GitLab URL in Team first'
	elif [[ -z $GITLAB_TOKEN ]]; then
		gitlab_message='No token yet'
	else
		status=$(gitlab_request 'query { currentUser { username } }' '{}' "$answer")
		username=$(jq -r '.data.currentUser.username // empty' "$answer" 2>/dev/null)
		rm -f "$answer"
		if [[ $status == 200 && -n $username ]]; then
			gitlab_ok=true
			gitlab_message="Signed in as $username"
		elif [[ $status == 401 || $status == 403 || $status == 200 ]]; then
			gitlab_message='GitLab rejected the token (expired, or without the read_api scope?)'
		elif [[ $status == 000 ]]; then
			gitlab_message='GitLab unreachable'
		else
			gitlab_message="GitLab answered with HTTP $status"
		fi
	fi
	jq -n --argjson jenkinsOk "$jenkins_ok" --arg jenkinsMessage "$jenkins_message" \
		--argjson gitlabOk "$gitlab_ok" --arg gitlabMessage "$gitlab_message" \
		'{jenkins: {ok: $jenkinsOk, message: $jenkinsMessage}, gitlab: {ok: $gitlabOk, message: $gitlabMessage}}'
}

case ${1:-} in
	--set) set_setting "$2" "$3"; exit 0 ;;
	--set-team) set_value "$team_file" "$2" "$3"; exit 0 ;;
	--label-filter) set_label_filter "$2" "$3"; exit ;;
	--clear-labels)
		set_setting work_items_with_labels ''
		set_setting work_items_without_labels ''
		exit 0
		;;
	--hide) printf '%s\t%s\n' "$2" "$3" >>"$hidden_file"; exit 0 ;;
	--unhide-all) : >"$hidden_file"; exit 0 ;;
	--check-now) rm -f "$last_poll_file" "$last_gitlab_poll_file"; [[ -f $jobs_file ]] && touch -t 200001010000 "$jobs_file"; exit 0 ;;
	--preview-success) "$watch" --test $(watch_flags); exit 0 ;;
	--preview-failure) "$watch" --test-failure $(watch_flags); exit 0 ;;
	--settings-json) settings_json; exit ;;
	--set-token) store_token "$2"; exit ;;
	--delete-token) delete_token "$2"; exit ;;
	--check-accounts) check_accounts; exit ;;
esac

if [[ -z $JOB_ROOT || -z $GITLAB_URL || -z $GITLAB_PROJECT ]]; then
	echo 'CI ⚠️'
	echo '---'
	echo 'Fill in the team settings: your Jenkins job and GitLab project | color=red'
	has_settings_app && echo "Open the team settings… | $(settings_action team)"
	echo "Open config/team.conf | bash=/usr/bin/open param1=-t param2=\"$team_file\" terminal=false"
	exit 0
fi

# SwiftBar runs this every 30 seconds; Jenkins and GitLab are only asked once their interval is (nearly) up.
due() {
	local last
	last=$(cat "$1" 2>/dev/null)
	[[ ! $last =~ ^[0-9]+$ ]] || (($(date +%s) - last >= $2 - 5))
}

due "$last_poll_file" "$(number_setting refresh_seconds 60)" && poll
# A changed setting may be a work item filter, so GitLab is asked again right away.
[[ $settings_file -nt $last_gitlab_poll_file ]] || due "$last_gitlab_poll_file" "$(number_setting gitlab_refresh_seconds 120)" && poll_gitlab
render
