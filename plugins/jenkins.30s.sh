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
# The jobs of others whose builds show like mine, one per line.
watched_file="$cache_dir/watched"
error_file="$cache_dir/error"
last_poll_file="$cache_dir/last-poll"
gitlab_file="$cache_dir/gitlab.json"
gitlab_error_file="$cache_dir/gitlab-error"
last_gitlab_poll_file="$cache_dir/last-gitlab-poll"
work_items_file="$cache_dir/work-items.json"
work_items_error_file="$cache_dir/work-items-error"
work_item_labels_file="$cache_dir/work-item-labels.json"
missing_labels_file="$cache_dir/missing-filter-labels"
label_colors_file="$cache_dir/label-colors.json"
related_dir="$cache_dir/related-merge-requests"
merged_file="$cache_dir/merged-merge-requests"
poll_lock="$cache_dir/poll.lock"
gitlab_icon_file="$tool_dir/icons/gitlab.png"
menubar_icon_file="$tool_dir/icons/menubar.png"
# Jenkins and GitLab answer within seconds, once connected.
connect_seconds=5
# The log of the settings window's Logs, where macOS apps keep theirs (Console.app opens it too), the times of the
# checks and the requests with their responses. The log starts a new file at 1 MB and keeps 4 old ones, the check times
# keep their newest half at 512 KB, the requests keep the newest 10 MB with the first 128 KB of each response: the logs
# never take more than 15.5 MiB (16.3 MB).
log_dir="$HOME/Library/Logs/jenkins-menubar"
log_file="$log_dir/jenkins-menubar.log"
checks_file="$log_dir/checks.tsv"
requests_dir="$log_dir/requests"
log_max_bytes=1048576
log_files=5
checks_max_bytes=524288
requests_max_bytes=10485760
request_body_max=131072
mkdir -p "$cache_dir" "${settings_file%/*}" "$log_dir"
touch "$state_file" "$hidden_file" "$rows_file" "$watched_file"
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
# A work item needs all of the must-have labels, or any one of them: all | any
work_items_labels_match=all
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

# The filter labels that GitLab did not have at the last check, as a JSON array.
missing_labels() {
	grep -v '^$' "$missing_labels_file" 2>/dev/null | jq -R . | jq -sc .
}

# set_label_filter <label> <with | without | any>: puts the label in the "with" or the "without" list, or in neither; a
# label is never in both.
set_label_filter() {
	[[ $2 == with || $2 == without || $2 == any ]] || return 2
	local key
	# A work item has one label per scope (all before the last "::"), so when it needs all must-have labels, a must-have
	# label replaces the one of its scope.
	if [[ $2 == with && $1 == *::* && $(setting work_items_labels_match all) == all ]]; then
		set_setting work_items_with_labels "$(list_setting work_items_with_labels | SCOPE="${1%::*}::" awk '
			index($0, ENVIRON["SCOPE"]) != 1 || index(substr($0, length(ENVIRON["SCOPE"]) + 1), "::")' | paste -sd , -)"
	fi
	for key in work_items_with_labels work_items_without_labels; do
		set_setting "$key" "$(list_setting "$key" | grep -vxF -- "$1" | paste -sd , -)"
	done
	[[ $2 == any ]] || set_setting "work_items_$2_labels" "$( (list_setting "work_items_$2_labels"; echo "$1") | paste -sd , -)"
}

# set_labels_match <all | any>: whether a work item needs all must-have labels or any one of them. For all, the last
# must-have label of each scope stays, since a work item never has two.
set_labels_match() {
	[[ $1 == all || $1 == any ]] || return 2
	local labels label
	set_setting work_items_labels_match "$1"
	[[ $1 == all ]] || return 0
	labels=$(list_setting work_items_with_labels)
	while IFS= read -r label; do
		[[ -n $label ]] && set_label_filter "$label" with
	done <<<"$labels"
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

# log <debug | info | warning | error> <menu | jenkins | gitlab | alerts | settings> <message> [detail] [outcome]
# [request]: a line in the log, tab-separated: the time, the level, the source, the message, the detail, the outcome as
# <ok | failed | warning | running | neutral>:<label> (like failed:TIMEOUT) and the request's file in requests_dir, with
# its response. Never log a token.
log() {
	local message=${3//[$'\t\r\n']/ } detail=${4:-}
	detail=${detail//[$'\t\r\n']/ }
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$1" "$2" "$message" "${detail:0:500}" "${5:-}" "${6:-}" \
		>>"$log_file" 2>/dev/null
}

file_size() {
	stat -f %z "$1" 2>/dev/null || echo 0
}

# Starts a new log once it passes log_max_bytes: the old ones move up a number and the oldest goes. The check times keep
# their newest half once they pass checks_max_bytes, the requests the newest that fit in requests_max_bytes (1000 at
# most, a file takes a few KB however small it is).
rotate_logs() {
	local n lines
	if (($(file_size "$log_file") > log_max_bytes)); then
		rm -f "$log_file.$((log_files - 1))"
		for ((n = log_files - 2; n >= 1; n--)); do
			[[ -f $log_file.$n ]] && mv "$log_file.$n" "$log_file.$((n + 1))"
		done
		mv "$log_file" "$log_file.1"
	fi
	if (($(file_size "$checks_file") > checks_max_bytes)); then
		lines=$(wc -l <"$checks_file")
		tail -n $((lines / 2)) "$checks_file" >"$checks_file.tmp" && mv "$checks_file.tmp" "$checks_file"
	fi
	# The names start with the time, so the newest sort first.
	[[ ! -d $requests_dir ]] || (cd "$requests_dir" && find . -name '*.json' -exec stat -f '%z %N' {} + | sort -k 2 -r |
		awk -v most="$requests_max_bytes" '{ total += $1 } total > most || NR > 1000 { print $2 }' | xargs rm -f)
}

# set_problem <error file> <source> [problem]: what is wrong, for the menu. Logged when it changes, not on every check;
# without a problem, the one before is logged as resolved.
set_problem() {
	local previous
	previous=$(cat "$1" 2>/dev/null)
	if [[ -n ${3:-} ]]; then
		[[ $3 == "$previous" ]] || log error "$2" "$3" '' failed:PROBLEM
		printf '%s\n' "$3" >"$1"
	elif [[ -n $previous ]]; then
		rm -f "$1"
		log info "$2" "Resolved: $previous" '' ok:RESOLVED
	fi
}

# The outcome of a build's result, for the log.
result_outcome() {
	case $1 in
		SUCCESS) echo ok:SUCCESS ;;
		FAILURE) echo failed:FAILURE ;;
		UNSTABLE) echo warning:UNSTABLE ;;
		*) echo "neutral:$1" ;;
	esac
}

# check_start <jenkins | gitlab>: a check of Jenkins or GitLab starts, and log_request notes the time of its requests,
# also those running in the background.
check_start() {
	request_times="$cache_dir/request-times.$1"
	: >"$request_times"
}

# check_done <jenkins | gitlab>: notes how many requests the check took, their time together and how many failed, in
# the check times for the Logs' chart.
check_done() {
	local requests seconds failed name=Jenkins outcome=ok:OK
	read -r requests seconds failed < <(
		awk -F '\t' '{ n++; s += $1; f += !$2 } END { printf "%d %.2f %d\n", n, s, f }' "$request_times"
	)
	rm -f "$request_times"
	request_times=''
	((requests > 0)) || return 0
	printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$seconds" "$requests" "$failed" >>"$checks_file"
	[[ $1 == gitlab ]] && name=GitLab
	((failed)) && outcome="failed:$failed FAILED"
	log debug "$1" "Checked $name: $requests request$( ((requests == 1)) || echo s), ${seconds}s together" '' "$outcome"
}

# save_request <method> <URL> <GraphQL query> <variables> <curl exit code> <HTTP status> <seconds> <response headers file>
# <response body file>: keeps the request with its response (the first request_body_max bytes of it) for the details of
# its log entry, and prints the name of its file. No token gets there: the request is kept without its Authorization
# header, the response without its cookies.
save_request() {
	local file
	mkdir -p "$requests_dir"
	file=$(mktemp "$requests_dir/$(date +%Y%m%d-%H%M%S)-XXXXXX") || return 0
	if jq -n --arg method "$1" --arg url "$2" --arg query "$3" --arg variables "$4" --argjson exit "$5" --arg status "$6" \
		--arg seconds "$7" --rawfile headers <(cat "$8" 2>/dev/null) \
		--rawfile body <(head -c "$request_body_max" "$9" 2>/dev/null) \
		--argjson bytes "$(file_size "$9")" --argjson most "$request_body_max" '{
			method: $method,
			url: $url,
			query: (if $query == "" then null else $query end),
			variables: (if $variables == "" then null else $variables end),
			exit: $exit,
			status: $status,
			seconds: ($seconds | tonumber? // 0),
			headers: ($headers | gsub("\r"; "") | split("\n") | map(select(test("^set-cookie:"; "i") | not))
				| join("\n") | sub("\n+$"; "")),
			bytes: $bytes,
			truncated: ($bytes > $most),
			body: $body
		}' >"$file" 2>/dev/null && mv "$file" "$file.json"; then
		printf '%s' "${file##*/}.json"
	else
		rm -f "$file"
	fi
}

# log_request <jenkins | gitlab> <request, like GET /api/json> <curl exit code> <HTTP status> <seconds> <seconds allowed>
# [request file]: logs a request, as debug when it worked, and notes its time for the check.
log_request() {
	local took ok=0
	printf -v took '%.2fs' "${5:-0}" 2>/dev/null || took="${5}s"
	case $3 in
		0)
			if [[ $4 == 2?? ]]; then
				ok=1
				log debug "$1" "$2 in $took" '' "ok:$4" "${7:-}"
			else
				log warning "$1" "$2: HTTP $4 in $took" '' "failed:$4" "${7:-}"
			fi
			;;
		28)
			# curl gives up without a connection after connect_seconds, without an answer once the time allowed is over.
			printf -v took '%.0f' "${5:-0}"
			if ((took < $6)); then
				log warning "$1" "$2: no connection within $connect_seconds seconds (VPN?)" '' failed:TIMEOUT "${7:-}"
			else
				log warning "$1" "$2: no answer within $6 seconds" '' failed:TIMEOUT "${7:-}"
			fi
			;;
		6) log warning "$1" "$2: unknown host (VPN?)" '' failed:OFFLINE "${7:-}" ;;
		7) log warning "$1" "$2: no connection (VPN?)" '' failed:OFFLINE "${7:-}" ;;
		*) log warning "$1" "$2: curl error $3" '' "failed:ERROR $3" "${7:-}" ;;
	esac
	[[ -z ${request_times:-} ]] || printf '%s\t%s\n' "${5:-0}" "$ok" >>"$request_times"
}

# api <path> [seconds to answer]: prints Jenkins' answer. Without one, prints the HTTP status instead (000 when Jenkins
# was not reached) and exits 22 for an HTTP error, with curl's code otherwise. The token goes to curl through a file
# descriptor, so it does not show up in ps.
api() {
	local written code status answer request
	answer=$(mktemp "$cache_dir/jenkins-answer.XXXXXX")
	written=$(curl -sS --connect-timeout "$connect_seconds" --max-time "${2:-20}" -D "$answer.headers" -o "$answer" \
		-w '%{http_code} %{time_total}' \
		-H @<(printf 'Authorization: Basic %s\n' "$JENKINS_MCP_BASIC_AUTH") "$JOB_ROOT$1" 2>/dev/null)
	code=$?
	status=${written%% *}
	request=$(save_request GET "$JOB_ROOT$1" '' '' "$code" "$status" "${written#* }" "$answer.headers" "$answer")
	log_request jenkins "GET ${1%%\?*}" "$code" "$status" "${written#* }" "${2:-20}" "$request"
	if ((code != 0)); then
		echo 000
	elif [[ $status != 2?? ]]; then
		printf '%s' "$status"
		code=22
	else
		cat "$answer"
	fi
	rm -f "$answer" "$answer.headers"
	return "$code"
}

# jenkins_problem <HTTP status printed by api>: what went wrong, for the menu and the settings window.
jenkins_problem() {
	case $1 in
		401 | 403) echo 'Jenkins rejected the token' ;;
		404) echo 'Jenkins does not know the job: check the job URL in Team' ;;
		000) echo 'Jenkins unreachable (VPN?)' ;;
		*) echo "Jenkins answered with HTTP $1" ;;
	esac
}

previous_state() {
	awk -F '\t' -v job="$1" '$1 == job' "$state_file"
}

# ── Watching the builds of others ──

url_decode() {
	printf '%b' "${1//%/\\x}"
}

# job_label <job>: how the menu names a job: !123 for MR-123, the branch for the others, like develop.
job_label() {
	if [[ $1 =~ ^MR-[0-9]+$ ]]; then
		printf '!%s' "${1#MR-}"
	else
		# A branch's job is its name URL-encoded twice, like feature%252Ffoo.
		url_decode "$(url_decode "$1")"
	fi
}

# watch_target <link>: the job to watch for a link someone pastes: a Jenkins build or job link into the Jenkins job of
# Team (a build stands for its job: the builds after it count too), a merge request link of the GitLab project of Team,
# or !123. Prints why not otherwise.
watch_target() {
	local text link path project root=${JOB_ROOT//%20/ } mr='^(!|MR-|mr-)?([0-9]+)$' merge_request='^merge_requests/([0-9]+)'
	local job='^/job/([^/?#]+)([/?#].*)?$'
	text="${1#"${1%%[![:space:]]*}"}"
	text="${text%"${text##*[![:space:]]}"}"
	# A link typed by hand may have a space where the browser has %20.
	link=${text//%20/ }
	if [[ $text =~ $mr ]]; then
		echo "MR-${BASH_REMATCH[2]}"
	elif [[ -n $GITLAB_URL && $text == "$GITLAB_URL"/*/-/* ]]; then
		path=${text#"$GITLAB_URL"/}
		project=${path%%/-/*}
		if [[ $(tr '[:upper:]' '[:lower:]' <<<"$project") != $(tr '[:upper:]' '[:lower:]' <<<"$GITLAB_PROJECT") ]]; then
			echo "That is not in $GITLAB_PROJECT, the GitLab project in Team"
			return 1
		fi
		[[ ${path#*/-/} =~ $merge_request ]] || { echo 'That GitLab link is not a merge request'; return 1; }
		echo "MR-${BASH_REMATCH[1]}"
	elif [[ $link == "$root"/job/* && ${link#"$root"} =~ $job ]]; then
		echo "${BASH_REMATCH[1]}"
	elif [[ $text == http://* || $text == https://* ]]; then
		echo "That is not a link into the Jenkins job in Team, $JOB_ROOT"
		return 1
	else
		echo 'Paste a link to a Jenkins build or a GitLab merge request, or !123'
		return 1
	fi
}

# watch <link>: watches all builds of the job of a link (see watch_target) once Jenkins confirmed it, and prints for the
# settings window the job, its label, the title and whether it is one of mine, which the menu shows anyway.
watch() {
	local job json title mine=false
	job=$(watch_target "$1") || { printf '%s\n' "$job" >&2; return 1; }
	JENKINS_MCP_BASIC_AUTH=$(token JENKINS_MCP_BASIC_AUTH)
	[[ -n $JENKINS_MCP_BASIC_AUTH ]] || { echo 'No Jenkins token: add it in Accounts' >&2; return 1; }
	if ! json=$(api "/job/$job/api/json?tree=actions%5BobjectDisplayName%5D"); then
		if [[ $json == 404 ]]; then echo "Jenkins has no job $(job_label "$job")" >&2; else jenkins_problem "$json" >&2; fi
		return 1
	fi
	title=$(jq -r '[.actions[]? | .objectDisplayName // empty][0] // empty' <<<"$json")
	if grep -qxF "$job" "$jobs_file" 2>/dev/null; then
		mine=true
	elif ! grep -qxF "$job" "$watched_file"; then
		printf '%s\n' "$job" >>"$watched_file"
		# The next run asks Jenkins right away.
		rm -f "$last_poll_file"
		log info jenkins "Watching $(job_label "$job")" "$title"
	fi
	jq -n --arg job "$job" --arg label "$(job_label "$job")" --arg title "$title" --argjson mine "$mine" \
		'{job: $job, label: $label, title: $title, mine: $mine}'
}

# unwatch <job> [why]: stops watching the job's builds.
unwatch() {
	awk -F '\t' -v job="$1" '$1 == job { found = 1 } END { exit !found }' "$watched_file" || return 0
	awk -F '\t' -v job="$1" '$1 != job' "$watched_file" >"$watched_file.tmp" && mv "$watched_file.tmp" "$watched_file"
	log info jenkins "Stopped watching $(job_label "$1")${2:+: $2}"
}

# hidden_by_settings <result> <seconds since it finished> <hide successful after> <hide failed after>: whether the hide
# settings (hours, 0 or immediately) take a finished build out of the menu by now.
hidden_by_settings() {
	local after=$4
	[[ $1 == SUCCESS ]] && after=$3
	[[ $after == immediately ]] || ((after > 0 && $2 > after * 3600))
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
		set_problem "$error_file" jenkins 'No Jenkins token: add it in Settings… → Accounts, or export JENKINS_MCP_BASIC_AUTH in ~/.zshrc'
		return
	fi
	# MR jobs name the GitLab author as contributor; the Jenkins login stands in for the GitLab username until GitLab answered.
	local me offline=0 problem='' code
	me=$(jq -r '.data.currentUser.username // empty' "$gitlab_file" 2>/dev/null)
	[[ -n $me ]] || me=$(printf '%s' "$JENKINS_MCP_BASIC_AUTH" | base64 --decode 2>/dev/null | cut -d : -f 1)

	# Listing all MR jobs takes seconds (more on a big Jenkins), so the set of my jobs is refreshed less often than the
	# builds, and Jenkins gets more time to answer.
	if [[ ! -f $jobs_file || -z $(find "$jobs_file" -mmin "-$DISCOVERY_MINUTES" 2>/dev/null) || $(cat "$jobs_user_file" 2>/dev/null) != "$me" ]]; then
		local discovered
		if discovered=$(api '/api/json?tree=jobs%5Bname,actions%5Bcontributor%5D%5D' 60); then
			jq -r --arg me "$me" '.jobs[] | select(any(.actions[]?; .contributor == $me)) | .name' <<<"$discovered" >"$jobs_file.tmp" &&
				mv "$jobs_file.tmp" "$jobs_file" && printf '%s\n' "$me" >"$jobs_user_file"
			log debug jenkins "Found $(grep -c . "$jobs_file") MR jobs of $me" "$(paste -sd ' ' "$jobs_file")"
		else
			code=$?
			problem=$(jenkins_problem "$discovered")
			# A list too slow to arrive says nothing about the far smaller answers for the builds, so those are still asked for.
			((code == 22 || code == 28)) || offline=1
			if [[ ! -f $jobs_file ]]; then
				set_problem "$error_file" jenkins "$problem"
				return
			fi
			# The list is only asked for again after the usual pause, so a slow Jenkins does not hold up every poll.
			if ((code == 28)); then
				touch "$jobs_file"
				log warning jenkins "The list of MR jobs took too long: the builds of the last list are checked" '' warning:SLOW
			fi
		fi
	fi

	local new_state="$cache_dir/state.new" new_rows="$cache_dir/rows.new" reached=0 flags stage_alerts
	local job kind json title mr_url author number building result started_ms estimate_ms duration_ms stages failed_stages
	local stages_json previous previous_row previous_number previous_building previous_failed finished_failed build_url
	flags=$(watch_flags)
	stage_alerts=$(setting stage_alerts on)
	: >"$new_state"
	: >"$new_rows"
	# My jobs, then the watched ones that are not mine: "<job>\t<mine | watched>".
	while IFS=$'\t' read -r job kind; do
		[[ -n $job ]] || continue
		previous=$(previous_state "$job")
		previous_row=$(awk -F '\t' -v job="$job" '$1 == job' "$rows_file")
		# Once Jenkins is not reached, every other job would only wait for its timeout too.
		code=1
		if ((!offline)); then
			json=$(api "/job/$job/api/json?tree=actions%5BobjectDisplayName,objectUrl,contributorDisplayName%5D,lastBuild%5Bnumber,building,result,timestamp,estimatedDuration,duration%5D")
			code=$?
			((code == 0 || code == 22)) || offline=1
			# Jenkins drops the job of a merged or closed MR: there is nothing left to show for it, nor to watch.
			if ((code == 22)) && [[ $json == 404 ]]; then
				[[ $kind == watched ]] && unwatch "$job" 'Jenkins no longer has it'
				continue
			fi
			((code == 0)) || problem=$(jenkins_problem "$json")
		fi
		if ((code != 0)); then
			# The build stays as it was, in the menu and hidden or not, until Jenkins answers for it again.
			[[ -n $previous ]] && printf '%s\n' "$previous" >>"$new_state"
			[[ -n $previous_row ]] && printf '%s\n' "$previous_row" >>"$new_rows"
			continue
		fi
		reached=1
		# No field may be empty: read merges neighbouring tabs and would shift the fields after it.
		IFS=$'\t' read -r title mr_url author number building result started_ms estimate_ms duration_ms < <(jq -r '[
			([.actions[]? | .objectDisplayName // empty | select(. != "")][0] // "-"),
			([.actions[]? | .objectUrl // empty | select(. != "")][0] // "-"),
			([.actions[]? | .contributorDisplayName // empty | select(. != "")][0] // "-"),
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
		[[ $building == true && $previous_number != "$number" ]] && log info jenkins "$job #$number started: $title" '' running:RUNNING
		if [[ -n $previous ]]; then
			if [[ $previous_number == "$number" && $previous_building == true && $building == false ]]; then
				log info jenkins "$job #$number finished" "$title" "$(result_outcome "$result")"
				nohup "$watch" $flags "$build_url" </dev/null >/dev/null 2>&1 &
			fi
			if [[ $stage_alerts == on && $building == true && -n $failed_stages && $failed_stages != "$previous_failed" ]]; then
				log info alerts "Banner: $job #$number stage failed: $failed_stages" "$title" failed:FAILED
				stage_banner "💥 $(job_label "$job") #$number: stage failed" "$failed_stages"$'\n'"$title" "$build_url"
			fi
		fi
		printf '%s\t%s\t%s\t%s\n' "$job" "$number" "$building" "$failed_stages" >>"$new_state"
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$job" "${title//$'\t'/ }" "$mr_url" "$number" "$building" "$result" \
			"$started_ms" "$estimate_ms" "$duration_ms" "${stages:--}" "${failed_stages:--}" "$kind" "${author//$'\t'/ }" >>"$new_rows"
	done < <(awk -F '\t' 'FILENAME == ARGV[1] { if ($1 != "") { mine[$1]; print $1 "\tmine" } next }
		$1 != "" && !($1 in mine) { print $1 "\twatched" }' "$jobs_file" "$watched_file")
	mv "$new_state" "$state_file"

	if ((!reached)) && [[ -n $problem ]]; then
		rm -f "$new_rows"
		set_problem "$error_file" jenkins "$problem"
		return
	fi
	sort -t $'\t' -k 7,7nr "$new_rows" >"$rows_file"
	rm -f "$new_rows"
	set_problem "$error_file" jenkins "$( ((offline)) && echo 'Jenkins unreachable (VPN?)')"

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

query MergeRequests {
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
# A "|" would start SwiftBar parameters (like bash=) and a line break a new menu item.
def clean: gsub("\\|"; "¦") | gsub("[\r\n]+"; " ");
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
# The status badge in front of a merge request: an SF Symbol of a round badge, in GitLab's colors of the light and the
# dark menu. Only round badges, so the titles line up.
def badge($text; $icon; $color): {$text, $icon, $color};
def green: "#108548,#52B87A";
def neutral: "#737278,#A4A3A8";
def orange: "#C17D10,#D99530";
def red: "#DD2B0E,#EC5941";
def blue: "#1F75CB,#428FDC";
def status:
	if .detailedMergeStatus == "MERGEABLE" then badge("Ready to merge"; "checkmark.circle.fill"; green)
	elif .draft then badge("Draft"; "pencil.circle.fill"; neutral)
	elif .headPipeline.status == "FAILED" then badge("Pipeline failed"; "xmark.circle.fill"; red)
	elif .detailedMergeStatus == "CONFLICT" then badge("Merge conflicts"; "exclamationmark.circle.fill"; red)
	elif .detailedMergeStatus == "NEED_REBASE" then badge("Needs a rebase"; "arrow.up.circle.fill"; orange)
	elif .detailedMergeStatus == "REQUESTED_CHANGES" then badge("Changes requested"; "exclamationmark.circle.fill"; orange)
	elif .detailedMergeStatus == "NOT_APPROVED" then badge(approvals; "hourglass.circle.fill"; neutral)
	elif .detailedMergeStatus == "DISCUSSIONS_NOT_RESOLVED" then badge("Unresolved threads"; "bubble.left.circle.fill"; orange)
	elif .detailedMergeStatus == "CI_STILL_RUNNING" then badge("Pipeline running"; "arrow.triangle.2.circlepath.circle.fill"; blue)
	elif .detailedMergeStatus | IN("UNCHECKED", "CHECKING", "PREPARING", "APPROVALS_SYNCING") then
		badge("Checking mergeability"; "ellipsis.circle.fill"; neutral)
	else badge(.detailedMergeStatus // "unknown" | ascii_downcase | gsub("_"; " "); "questionmark.circle.fill"; neutral) end;
def details($me; $state):
	[(.reference | ref), $state, (if .author.username != $me then "by \(.author.name)" else empty end), (.updatedAt | updated),
		"\(.diffStatsSummary.fileCount // 0 | count("file")) +\(.diffStatsSummary.additions // 0) −\(.diffStatsSummary.deletions // 0)",
		(if .headPipeline.status then "pipeline \(.headPipeline.status | ascii_downcase)" else empty end)]
	| map(select(. != "")) | join(" · ") | clean | gsub("\""; "'");
# SwiftBar draws the :name: in front of the title as that SF Symbol, in the sfcolor.
def entry($me; $requested):
	(if $requested then badge("Review requested · \(status.text)"; "eye.circle.fill"; orange) else status end) as $badge
	| "--:\($badge.icon): \(.title | clean | shorten(60)) | href=\(.webUrl) sfcolor=\($badge.color) tooltip=\"\(details($me; $badge.text))\"";
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
| "GitLab merge requests\(if ($counts | length) > 0 then " · " + ($counts | join(" · ")) else "" end)\($params)",
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
  labels(first: 30) { nodes { title color } }
}

query WorkItems($assignee: [String!], $author: String, $types: [IssueType!], $state: IssuableState, $sort: IssueSort,
      $withCommitted: Boolean!, $committedLabels: [String], $committedOr: UnionedIssueFilterInput,
      $committedNot: NegatedIssueFilterInput, $withOthers: Boolean!, $otherLabels: [String],
      $otherOr: UnionedIssueFilterInput, $otherNot: NegatedIssueFilterInput, $first: Int) {
  committed: issues(assigneeUsernames: $assignee, authorUsername: $author, types: $types, state: $state,
      labelName: $committedLabels, or: $committedOr, not: $committedNot, sort: $sort, first: 50) @include(if: $withCommitted) {
    count
    nodes { ...item }
  }
  others: issues(assigneeUsernames: $assignee, authorUsername: $author, types: $types, state: $state,
      labelName: $otherLabels, or: $otherOr, not: $otherNot, sort: $sort, first: $first) @include(if: $withOthers) {
    count
    nodes { ...item }
  }
}
GRAPHQL

# Turns the work items answer (or null) into the "GitLab work items" submenu, including the filter and sort controls.
read -r -d '' WORK_ITEMS_MENU <<'JQ'
def shorten($max): if length > $max then .[0:$max - 1] + "…" else . end;
# A "|" would start SwiftBar parameters (like bash=) and a line break a new menu item.
def clean: gsub("\\|"; "¦") | gsub("[\r\n]+"; " ");
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
		(if $match == "any" and ($with | length) > 1 then "+(\($with | map(valueOf) | join(" or ")))" else $with[] | "+" + valueOf end),
		($without[] | "−" + valueOf)]
	| join(" · ") | clean;
def entry:
	# Automatic MRs (like cascades between release branches) only mention the work item, they are not work on it.
	[$related[.reference].mergeRequests[]? | select((.state == "opened" or .state == "merged")
		and ($ignoredPrefix == "" or (.title | startswith($ignoredPrefix) | not)))] as $mergeRequests
	| ([slot // empty, mergeRequestMark($mergeRequests)] | join(" ") | clean) as $prefix
	| "--\(.reference | shortRef)  \(if $prefix != "" then "\($prefix) · " else "" end)\(.title | clean | shorten(if $prefix != "" then 52 else 60 end)) | href=\(.webUrl)";
def section($title):
	if . != null and (.nodes | length) > 0
	then "--\($title) (\(countText)) | size=12 color=#8E8E93", (.nodes[] | entry), "-----"
	else empty end;

($result.data // null) as $data
| ($data.committed // null) as $committedItems
| ($data.others // null) as $otherItems
| [$missing[] | select(IN(($with + $without)[]))] as $missingFilters
| "GitLab work items\(if $data == null then "" elif ($committedItems.count // 0) > 0 then " · \($committedItems.count) committed" else " (\($otherItems // {count: 0, nodes: []} | countText))" end)\(if $problem != "" or ($missingFilters | length) > 0 then " ⚠️" else "" end)\($params)",
	(if $problem != "" then "--\($problem | clean) | color=red" else empty end),
	($missingFilters[] | "--⚠️ Filter label \(clean) is not in GitLab any more | color=red \($filtersAction)"),
	($committedItems | section("🟣 Committed")),
	($otherItems | section(if $committedLabel == "" then "Work items" else "Not committed" end)),
	(if $data != null and ([$committedItems, $otherItems] | map(.nodes // [] | length) | add) == 0
		then "--No work items match the filter | color=#8E8E93", "-----" else empty end),
	(if $data == null then "-----" else empty end),
	"--\(filters) | size=12 color=#8E8E93",
	"--Filters… | \($filtersAction)",
	"-----",
	"--All work items in GitLab | href=\($allWorkItems)",
	(if $checked != "" then "--Last checked \($checked) | size=12 color=#8E8E93" else empty end)
JQ

# Writes the response body to $3 and prints the HTTP status (000 when GitLab was not reached). The token goes to curl
# through a file descriptor, so it does not show up in ps. The log names the request after the query's name.
gitlab_request() {
	local written code status request name=GraphQL named='query ([A-Za-z]+)'
	[[ $1 =~ $named ]] && name=${BASH_REMATCH[1]}
	written=$(curl -sS --connect-timeout "$connect_seconds" --max-time 30 -D "$3.headers" -o "$3" -w '%{http_code} %{time_total}' \
		-H @<(printf 'Authorization: Bearer %s\n' "$GITLAB_TOKEN") -H 'Content-Type: application/json' \
		-d "$(jq -n --arg query "$1" --argjson variables "$2" '{query: $query, variables: $variables}')" "$GITLAB_URL/api/graphql" 2>/dev/null)
	code=$?
	status=${written%% *}
	request=$(save_request POST "$GITLAB_URL/api/graphql" "$1" "$2" "$code" "$status" "${written#* }" "$3.headers" "$3")
	rm -f "$3.headers"
	log_request gitlab "POST $name" "$code" "$status" "${written#* }" 30 "$request"
	printf '%s' "$status"
}

work_items_variables() {
	jq -n --arg me "$1" --arg scope "$(setting work_items_scope assigned)" --arg type "$(setting work_items_type all)" \
		--arg state "$(setting work_items_state opened)" --argjson with "$(label_list work_items_with_labels)" \
		--argjson without "$(label_list work_items_without_labels)" \
		--arg sort "$(setting work_items_sort UPDATED_DESC)" --argjson first "$(number_setting work_items_limit 20)" \
		--arg match "$(setting work_items_labels_match all)" --arg committed "$COMMITTED_LABEL" '
		# With any of the must-have labels, labelName (all of them) only keeps the committed label.
		($match == "any" and ($with | length) > 0) as $any
		| {
			assignee: (if $scope == "authored" then null else [$me] end),
			author: (if $scope == "authored" then $me else null end),
			types: (if $type == "all" then null else [$type] end),
			state: $state,
			sort: $sort,
			withCommitted: ($committed != "" and ($committed | IN($without[]) | not)),
			committedLabels: (if $any then [$committed] else $with + [$committed] | unique end),
			committedOr: (if $any then {labelNames: $with} else null end),
			committedNot: (if ($without | length) > 0 then {labelName: $without} else null end),
			withOthers: ($any or $committed == "" or ($committed | IN($with[]) | not)),
			otherLabels: (if $any or ($with | length) == 0 then null else $with end),
			otherOr: (if $any then {labelNames: $with} else null end),
			otherNot: (($without + [$committed] | map(select(. != "")) | unique) as $not
				| if ($not | length) > 0 then {labelName: $not} else null end),
			first: $first
		}'
}

read -r -d '' RELATED_QUERY <<'GRAPHQL'
query RelatedMergeRequests($path: ID!, $iid: String!) {
  project(fullPath: $path) {
    issue(iid: $iid) {
      relatedMergeRequests(first: 10) { nodes { iid state title webUrl reference(full: true) } }
    }
  }
}
GRAPHQL

# GitLab's labels of the project and its groups whose title, or description, contains the term.
read -r -d '' LABELS_QUERY <<'GRAPHQL'
query Labels($path: ID!, $term: String!) {
  project(fullPath: $path) { labels(searchTerm: $term, includeAncestorGroups: true, first: 100) { nodes { title color } } }
}
GRAPHQL

# remember_label_colors <GitLab answer>: adds the colors of the labels in it to those the settings window draws them in.
remember_label_colors() {
	[[ -s $label_colors_file ]] || echo '{}' >"$label_colors_file"
	# The settings window can search while a poll runs.
	jq -s '.[0] + ([.[1] | .. | objects | select(has("title") and (.color | type) == "string") | {key: .title, value: .color}] | from_entries)' \
		"$label_colors_file" "$1" >"$label_colors_file.$$" 2>/dev/null && mv "$label_colors_file.$$" "$label_colors_file"
	rm -f "$label_colors_file.$$"
}

# The remembered colors of the labels, as a JSON object from title to color.
label_colors() {
	cat "$label_colors_file" 2>/dev/null || echo '{}'
}

# Notes the filter labels that GitLab no longer has (renamed or removed), for the menu and the settings window. A label
# one of the work items has exists; GitLab is asked about the others.
check_filter_labels() {
	local label answer="$cache_dir/filter-label.json"
	{ list_setting work_items_with_labels; list_setting work_items_without_labels; } | while IFS= read -r label; do
		jq -e --arg label "$label" 'any(.data[]?.nodes[]?.labels.nodes[]?; .title == $label)' "$work_items_file" >/dev/null && continue
		[[ $(gitlab_request "$LABELS_QUERY" "$(jq -n --arg path "$GITLAB_PROJECT" --arg term "$label" '{path: $path, term: $term}')" "$answer") == 200 ]] ||
			continue
		remember_label_colors "$answer"
		jq -e --arg label "$label" '.data.project.labels.nodes | any(.title == $label) | not' "$answer" >/dev/null && printf '%s\n' "$label"
	done >"$missing_labels_file.new"
	touch "$missing_labels_file"
	awk 'NR == FNR { known[$0]; next } !($0 in known)' "$missing_labels_file" "$missing_labels_file.new" | while IFS= read -r label; do
		log warning gitlab "The filter label $label is not in GitLab any more (renamed or removed?)" '' warning:MISSING
	done
	mv "$missing_labels_file.new" "$missing_labels_file"
	rm -f "$answer"
}

fetch_related_merge_requests() {
	local reference=$1 updated=$2 file=$3
	gitlab_request "$RELATED_QUERY" "$(jq -n --arg path "${reference%#*}" --arg iid "${reference##*#}" '{path: $path, iid: $iid}')" "$file.new" >/dev/null
	# Swapped in whole: a run that only renders can read the folder while this one polls.
	if jq -e '.data.project.issue' "$file.new" >/dev/null 2>&1; then
		jq --arg reference "$reference" --arg updated "$updated" \
			'{reference: $reference, updatedAt: $updated, mergeRequests: .data.project.issue.relatedMergeRequests.nodes}' "$file.new" >"$file.tmp" &&
			mv "$file.tmp" "$file"
	fi
	rm -f "$file.new" "$file.tmp"
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
query MergedMergeRequests($path: ID!, $iids: [String!]) {
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
		set_problem "$gitlab_error_file" gitlab
		refresh_merged_merge_requests
	else
		rm -f "$gitlab_file.new"
		# 403 is a token without the read_api scope.
		if [[ $status == 401 || $status == 403 || $status == 200 ]]; then
			set_problem "$gitlab_error_file" gitlab 'GitLab rejected the token (expired, or without the read_api scope?)'
		else
			set_problem "$gitlab_error_file" gitlab "GitLab unreachable (HTTP $status)"
		fi
		return
	fi

	status=$(gitlab_request "$WORK_ITEMS_QUERY" "$(work_items_variables "$(jq -r '.data.currentUser.username' "$gitlab_file")")" "$work_items_file.new")
	if [[ $status == 200 ]] && jq -e '.data and (.errors | not)' "$work_items_file.new" >/dev/null 2>&1; then
		mv "$work_items_file.new" "$work_items_file"
		set_problem "$work_items_error_file" gitlab
		refresh_related_merge_requests
		remember_label_colors "$work_items_file"
		check_filter_labels
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
		local problem
		problem=$(jq -r '.errors[0].message // empty' "$work_items_file.new" 2>/dev/null | head -n 1)
		set_problem "$work_items_error_file" gitlab "${problem:-Work items request failed (HTTP $status)}"
		rm -f "$work_items_file.new"
	fi
}

# submenu_params <url> [logo]: the SwiftBar parameters of a menu item with a submenu, with the GitLab logo (32px saved at
# 144 DPI, so it draws at 16pt like the menu text) when asked for. A click on such an item opens its submenu, not the
# href: the href is there because SwiftBar 2.1.0 and 2.1.1 grey out an item with a submenu and no action of its own for
# good once its line changes, like a count in its title (swiftbar/SwiftBar#512, fixed in 2.1.2).
submenu_params() {
	printf ' | href=%s' "$1"
	if [[ ${2:-} == logo && -s $gitlab_icon_file ]]; then
		printf ' image=%s' "$(base64 <"$gitlab_icon_file" | tr -d '\n')"
	fi
}

# menubar_logo [text]: the menubar's line with the Jenkins butler (36px saved at 144 DPI, so 18pt high) before the text.
# It is a template image, which macOS draws black on a light menubar and white on a dark one, like its own icons.
menubar_logo() {
	if [[ -s $menubar_icon_file ]]; then
		echo "${1:-} | templateImage=$(base64 <"$menubar_icon_file" | tr -d '\n')"
	else
		echo "CI${1:+ $1}"
	fi
}

render_work_items() {
	local scope state me all_work_items
	scope=$(setting work_items_scope assigned)
	state=$(setting work_items_state opened)
	me=$(jq -r '.data.currentUser.username // empty' "$gitlab_file" 2>/dev/null)
	all_work_items="$GITLAB_URL/dashboard/issues?$([[ $scope == authored ]] && echo author_username || echo assignee_username)=$me&state=$state"
	if [[ ! -s $gitlab_file && ! -s $work_items_file ]]; then
		echo "GitLab work items$(submenu_params "$GITLAB_URL/dashboard/issues" logo)"
		echo '--Needs the GitLab token, see GitLab merge requests | color=#8E8E93'
		return
	fi
	local result=null checked=''
	[[ -s $work_items_file ]] && result=$(cat "$work_items_file")
	[[ -s $last_gitlab_poll_file ]] && checked=$(date -r "$(cat "$last_gitlab_poll_file")" +%H:%M)
	jq -nr --argjson result "$result" --arg problem "$(cat "$work_items_error_file" 2>/dev/null)" \
		--arg project "$GITLAB_PROJECT" --arg allWorkItems "$all_work_items" \
		--arg scope "$scope" --arg type "$(setting work_items_type all)" \
		--arg state "$state" --argjson with "$(label_list work_items_with_labels)" \
		--argjson without "$(label_list work_items_without_labels)" --argjson missing "$(missing_labels)" \
		--arg match "$(setting work_items_labels_match all)" \
		--argjson related "$(cat "$related_dir"/*.json 2>/dev/null | jq -sc 'map({key: .reference, value: .}) | from_entries' 2>/dev/null || echo '{}')" \
		--arg checked "$checked" --arg params "$(submenu_params "$all_work_items" logo)" --arg filtersAction "$(settings_action gitlab)" \
		--arg slotPrefix "$SLOT_LABEL_PREFIX" --arg ignoredPrefix "$IGNORED_MR_PREFIX" --arg committedLabel "$COMMITTED_LABEL" "$WORK_ITEMS_MENU"
}

render_gitlab() {
	if [[ -s $gitlab_file ]]; then
		jq -r --arg project "$GITLAB_PROJECT" --arg dashboard "$GITLAB_URL/dashboard/merge_requests" \
			--arg checked "$(date -r "$(cat "$last_gitlab_poll_file")" +%H:%M)" \
			--arg params "$(submenu_params "$GITLAB_URL/dashboard/merge_requests" logo)" "$GITLAB_MENU" "$gitlab_file"
		[[ -s $gitlab_error_file ]] && echo "--⚠️ $(cat "$gitlab_error_file") | color=red"
	elif [[ -s $gitlab_error_file ]]; then
		echo "GitLab merge requests ⚠️$(submenu_params "$GITLAB_URL/dashboard/merge_requests" logo)"
		echo "--$(cat "$gitlab_error_file") | color=red"
		echo "--Check now | bash=\"$self\" param1=--check-now terminal=false refresh=true"
	else
		echo "GitLab merge requests$(submenu_params "$GITLAB_URL/dashboard/merge_requests" logo)"
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
# watching, gitlab, accounts, team or logs); without the app, which install.sh builds, the settings file in a text
# editor. A URL the app handles, because macOS brings an app to the front for a URL SwiftBar opens, but not for an app
# that bash= starts.
settings_action() {
	if has_settings_app; then
		printf 'href=jenkins-menubar://settings/%s' "$1"
	else
		printf 'bash=/usr/bin/open param1=-t param2="%s" terminal=false' "$settings_file"
	fi
}

render() {
	local now hide_successful hide_failed hide_merged running=0 failed=0 unstable=0 green=0 hidden_count=0 menu='' watched='' summary=''
	local job title mr_url number building result started_ms estimate_ms duration_ms stages failed_stages kind author
	local build_url icon label detail elapsed left finished_age last_poll item
	now=$(date +%s)
	hide_successful=$(hide_setting hide_successful_after_hours 24)
	hide_failed=$(hide_setting hide_failed_after_hours 168)
	hide_merged=$(setting hide_merged on)

	while IFS=$'\t' read -r job title mr_url number building result started_ms estimate_ms duration_ms stages failed_stages kind author; do
		[[ -n $job ]] || continue
		[[ $hide_merged == on ]] && grep -qxF "${job#MR-}" "$merged_file" 2>/dev/null && continue
		if [[ $building != true ]]; then
			finished_age=$((now - (started_ms + duration_ms) / 1000))
			hidden_by_settings "$result" "$finished_age" "$hide_successful" "$hide_failed" && continue
		fi
		if grep -qxF "$job"$'\t'"$number" "$hidden_file"; then
			hidden_count=$((hidden_count + 1))
			continue
		fi
		[[ $stages != - ]] || stages=''
		[[ $failed_stages != - ]] || failed_stages=''
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

		[[ ${author:--} != - && $kind == watched ]] && detail="by $author · $detail"

		# Truncated here rather than with SwiftBar's length=, which adds a tooltip that covers the submenu.
		label="$icon ${title//|/¦}"
		((${#label} > 70)) && label="${label:0:69}…"
		item="$label$(submenu_params "$build_url")"$'\n'
		item+="--${detail//|/¦} | color=#8E8E93 href=$build_url"$'\n'
		item+="-----"$'\n'
		if [[ $mr_url != - && $job == MR-* ]]; then
			item+="--🦊 Open merge request $(job_label "$job") in GitLab | href=$mr_url"$'\n'
		elif [[ $mr_url != - ]]; then
			item+="--🦊 Open branch $(job_label "$job") in GitLab | href=$mr_url"$'\n'
		fi
		item+="--👷‍♂️ Open build #$number | href=$build_url"$'\n'
		item+="--📜 Console output | href=${build_url}console"$'\n'
		item+="--🧪 Test results | href=${build_url}testReport"$'\n'
		item+="-----"$'\n'
		item+="--🙈 Hide from menu until the next build | bash=\"$self\" param1=--hide param2=$job param3=$number terminal=false refresh=true"$'\n'
		if [[ $kind == watched ]]; then
			item+="--👀 Stop watching $(job_label "$job") | bash=\"$self\" param1=--unwatch param2=$job terminal=false refresh=true"$'\n'
			watched+=$item
		else
			menu+=$item
		fi
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
	if [[ -n $summary ]]; then
		echo "$summary | emojize=false"
	else
		menubar_logo
	fi

	echo '---'
	[[ -s $error_file ]] && echo "$(cat "$error_file") | color=red"
	if [[ -n $menu ]]; then
		printf '%s' "$menu"
	elif [[ ! -s $jobs_file && -s $jobs_user_file ]]; then
		# Names the user the jobs were looked up for, which helps when the Jenkins and the GitLab username differ.
		echo "No merge request builds by $(cat "$jobs_user_file") in Jenkins | color=#8E8E93"
	elif [[ -z $watched ]]; then
		echo 'No builds to show | color=#8E8E93'
	fi
	if [[ -n $watched ]]; then
		echo '---'
		echo 'Watching | size=12 color=#8E8E93'
		printf '%s' "$watched"
	fi

	echo '---'
	render_gitlab
	render_work_items

	echo '---'
	((hidden_count == 1)) && echo "Show 1 hidden build | bash=\"$self\" param1=--unhide-all terminal=false refresh=true"
	((hidden_count > 1)) && echo "Show $hidden_count hidden builds | bash=\"$self\" param1=--unhide-all terminal=false refresh=true"
	last_poll=$(cat "$last_poll_file" 2>/dev/null)
	echo "Check now${last_poll:+ (last checked $(date -r "$last_poll" +%H:%M))} | bash=\"$self\" param1=--check-now terminal=false refresh=true"
	# Someone else's build, followed like mine: in the settings window, which takes a pasted link.
	has_settings_app && echo "Watch a Build… | $(settings_action watching)"
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

# The watched jobs for the settings window, with what the last check found: the last build, whether it runs, its result,
# the title and the author.
watched_json() {
	awk -F '\t' 'FILENAME == ARGV[1] { row[$1] = $0; next } $1 != "" { print $1 "\t" (($1 in row) ? row[$1] : "") }' \
		"$rows_file" "$watched_file" | jq -Rn --arg root "$JOB_ROOT" '[inputs | split("\t") | {
			job: .[0],
			label: (.[0] | if test("^MR-[0-9]+$") then "!" + ltrimstr("MR-") else gsub("%25"; "%") | gsub("%2F"; "/") end),
			title: (.[2] // "" | if . == "" or . == "-" then null else . end),
			build: (.[4] // "" | tonumber? // null),
			building: (.[5] == "true"),
			result: (.[6] // "" | if . == "" or . == "NONE" then null else . end),
			author: (.[13] // "" | if . == "" or . == "-" then null else . end),
			url: "\($root)/job/\(.[0])/\(.[4] // "" | if . == "" then "" else . + "/" end)"
		}]'
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
			work_items_labels_match=all work_items_sort=UPDATED_DESC work_items_limit=20; do
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
		--argjson without "$(label_list work_items_without_labels)" --argjson missing "$(missing_labels)" \
		--argjson colors "$(label_colors)" --arg jenkinsSource "$(token_source JENKINS_MCP_BASIC_AUTH)" \
		--arg jenkinsUser "$(token JENKINS_MCP_BASIC_AUTH | base64 --decode 2>/dev/null | cut -d : -f 1)" \
		--arg gitlabSource "$(token_source GITLAB_TOKEN)" --arg settingsFile "$settings_file" --arg teamFile "$team_file" \
		--argjson watched "$(watched_json)" \
		--arg logFile "$log_file" --arg checksFile "$checks_file" --arg requestsDir "$requests_dir" \
		--argjson logsMaxBytes $((log_max_bytes * log_files + checks_max_bytes + requests_max_bytes)) \
		--arg jenkinsRoot "${JOB_ROOT%%/job/*}" --arg gitlabUrl "$GITLAB_URL" '{
		settings: $settings,
		team: $team,
		labels: ($known + $with + $without | unique),
		missingLabels: [$missing[] | select(IN(($with + $without)[]))],
		labelColors: ($colors | with_entries(select(.key | IN(($with + $without)[])))),
		tokens: {jenkins: {source: $jenkinsSource, user: $jenkinsUser}, gitlab: {source: $gitlabSource, user: ""}},
		watched: $watched,
		files: {settings: $settingsFile, team: $teamFile},
		# The log, with its older files next to it as .1, .2, …, the check times (time, jenkins | gitlab, seconds, requests,
		# failed requests, tab-separated) and the requests with their responses: the window reads them itself.
		logs: {file: $logFile, checks: $checksFile, requests: $requestsDir, maxBytes: $logsMaxBytes},
		links: {
			jenkinsToken: (if $jenkinsRoot == "" then null else "\($jenkinsRoot)/me/" end),
			gitlabToken: (if $gitlabUrl == "" then null
				else "\($gitlabUrl)/-/user_settings/personal_access_tokens?name=Jenkins%20menubar&scopes=read_api" end)
		}
	}'
}

# search_labels <text>: the labels whose title contains the text (all without one) for the label filters' Add…, as JSON:
# those of the work items and the filters, and GitLab's, with a problem when GitLab's are missing.
search_labels() {
	local known='[]' found='[]' problem='' answer
	[[ -s $work_item_labels_file ]] && known=$(jq -c 'if type == "array" then . else keys end' "$work_item_labels_file" 2>/dev/null || echo '[]')
	GITLAB_TOKEN=$(token GITLAB_TOKEN)
	if [[ -z $1 ]]; then
		:
	elif [[ -z $GITLAB_TOKEN ]]; then
		problem='No GitLab token: only the labels of your work items'
	else
		# Typing starts a search per pause, and an older one can still run.
		answer=$(mktemp "$cache_dir/search-labels.XXXXXX")
		if [[ $(gitlab_request "$LABELS_QUERY" "$(jq -n --arg path "$GITLAB_PROJECT" --arg term "$1" '{path: $path, term: $term}')" "$answer") != 200 ]] ||
			! found=$(jq -c '[.data.project.labels.nodes[].title]' "$answer" 2>/dev/null); then
			found='[]'
			problem='GitLab did not answer: only the labels of your work items'
		else
			remember_label_colors "$answer"
		fi
		rm -f "$answer"
	fi
	# GitLab also finds labels by their description.
	jq -n --arg text "$1" --argjson known "$known" --argjson found "$found" --argjson with "$(label_list work_items_with_labels)" \
		--argjson without "$(label_list work_items_without_labels)" --argjson colors "$(label_colors)" --arg problem "$problem" '
		($known + $with + $without + $found | unique | map(select(ascii_downcase | contains($text | ascii_downcase)))) as $labels
		| {
			labels: $labels,
			colors: ($colors | with_entries(select(.key | IN($labels[])))),
			problem: (if $problem == "" then null else $problem end)
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

# log_account_check <jenkins | gitlab> <true | false> <message>
log_account_check() {
	if [[ $2 == true ]]; then
		log info "$1" "Account check: $3" '' ok:OK
	else
		log warning "$1" "Account check: $3" '' failed:FAILED
	fi
}

# Asks Jenkins and GitLab with the tokens the menu uses: JSON with ok and a message for each.
check_accounts() {
	local jenkins_ok=false jenkins_message jenkins_answer gitlab_ok=false gitlab_message status username answer="$cache_dir/check-accounts.json"
	JENKINS_MCP_BASIC_AUTH=$(token JENKINS_MCP_BASIC_AUTH)
	GITLAB_TOKEN=$(token GITLAB_TOKEN)
	if [[ -z $JOB_ROOT ]]; then
		jenkins_message='Set the Jenkins job in Team first'
	elif [[ -z $JENKINS_MCP_BASIC_AUTH ]]; then
		jenkins_message='No token yet'
	elif jenkins_answer=$(api '/api/json?tree=name'); then
		jenkins_ok=true
		jenkins_message="Signed in as $(printf '%s' "$JENKINS_MCP_BASIC_AUTH" | base64 --decode 2>/dev/null | cut -d : -f 1)"
	else
		jenkins_message=$(jenkins_problem "$jenkins_answer")
	fi
	if [[ -z $GITLAB_URL ]]; then
		gitlab_message='Set the GitLab URL in Team first'
	elif [[ -z $GITLAB_TOKEN ]]; then
		gitlab_message='No token yet'
	else
		status=$(gitlab_request 'query CurrentUser { currentUser { username } }' '{}' "$answer")
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
	log_account_check jenkins "$jenkins_ok" "$jenkins_message"
	log_account_check gitlab "$gitlab_ok" "$gitlab_message"
	jq -n --argjson jenkinsOk "$jenkins_ok" --arg jenkinsMessage "$jenkins_message" \
		--argjson gitlabOk "$gitlab_ok" --arg gitlabMessage "$gitlab_message" \
		'{jenkins: {ok: $jenkinsOk, message: $jenkinsMessage}, gitlab: {ok: $gitlabOk, message: $gitlabMessage}}'
}

# log_change <key> <old value> <new value> [where]: a changed setting, for the log.
log_change() {
	[[ $2 == "$3" ]] || log info settings "${4:-}$1: ${2:-(empty)} → ${3:-(empty)}"
}

log_label_filter() {
	case $2 in
		with) log info settings "Work items must have the label $1" ;;
		without) log info settings "Work items must not have the label $1" ;;
		any) log info settings "The label $1 is out of the work item filters" ;;
	esac
}

token_label() {
	[[ $1 == GITLAB_TOKEN ]] && echo GitLab || echo Jenkins
}

case ${1:-} in
	--set) log_change "$2" "$(setting "$2" '')" "$3"; set_setting "$2" "$3"; exit 0 ;;
	--set-team) log_change "$2" "$(team_value "$2")" "$3" 'team.conf '; set_value "$team_file" "$2" "$3"; exit 0 ;;
	--label-filter) set_label_filter "$2" "$3" && log_label_filter "$2" "$3"; exit ;;
	--label-match) set_labels_match "$2" && log info settings "Work items need $2 of the must-have labels"; exit ;;
	--clear-labels)
		set_setting work_items_with_labels ''
		set_setting work_items_without_labels ''
		log info settings 'Cleared the work item label filters'
		exit 0
		;;
	--hide) printf '%s\t%s\n' "$2" "$3" >>"$hidden_file"; log info menu "Hid $2 #$3"; exit 0 ;;
	--unhide-all) : >"$hidden_file"; log info menu 'Showed the hidden builds again'; exit 0 ;;
	--check-now)
		rm -f "$last_poll_file" "$last_gitlab_poll_file"
		[[ -f $jobs_file ]] && touch -t 200001010000 "$jobs_file"
		log info menu 'Check now'
		exit 0
		;;
	--preview-success) log info alerts 'Preview of the success alert'; "$watch" --test $(watch_flags); exit 0 ;;
	--preview-failure) log info alerts 'Preview of the failure alert'; "$watch" --test-failure $(watch_flags); exit 0 ;;
	--settings-json) settings_json; exit ;;
	--watch) watch "${2:-}"; exit ;;
	--unwatch) unwatch "$2" 'stopped by hand'; exit 0 ;;
	--search-labels) search_labels "${2:-}"; exit ;;
	--set-token)
		store_token "$2"
		code=$?
		((code)) || log info settings "Saved the $(token_label "$2") token in the keychain"
		exit "$code"
		;;
	--delete-token) delete_token "$2" && log info settings "Removed the $(token_label "$2") token from the keychain"; exit ;;
	--check-accounts) check_accounts; exit ;;
	--clear-logs) rm -rf "$log_file" "$log_file".* "$checks_file" "$requests_dir"; log info settings 'Cleared the logs'; exit 0 ;;
esac

if [[ -z $JOB_ROOT || -z $GITLAB_URL || -z $GITLAB_PROJECT ]]; then
	menubar_logo ⚠️
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

# SwiftBar can start the plugin while a run still polls (Check now, a refresh from the settings window). Two polls would
# write the same files and alert twice, so one polls at a time; a lock whose run is gone (killed, say) does not count.
take_poll_lock() {
	if ! (set -o noclobber; echo $$ >"$poll_lock") 2>/dev/null; then
		kill -0 "$(cat "$poll_lock" 2>/dev/null)" 2>/dev/null && return 1
		rm -f "$poll_lock"
		(set -o noclobber; echo $$ >"$poll_lock") 2>/dev/null || return 1
	fi
	trap 'rm -f "$poll_lock"' EXIT
}

# Without the lock, the menu comes from the cache that the other run is refreshing.
if take_poll_lock; then
	rotate_logs
	if due "$last_poll_file" "$(number_setting refresh_seconds 60)"; then
		check_start jenkins
		poll
		check_done jenkins
	fi
	# A changed setting may be a work item filter, so GitLab is asked again right away.
	if [[ $settings_file -nt $last_gitlab_poll_file ]] || due "$last_gitlab_poll_file" "$(number_setting gitlab_refresh_seconds 120)"; then
		check_start gitlab
		poll_gitlab
		check_done gitlab
	fi
	rm -f "$poll_lock"
	trap - EXIT
else
	log debug menu 'Another run is checking Jenkins and GitLab: the menu shows what they answered last'
fi
render
