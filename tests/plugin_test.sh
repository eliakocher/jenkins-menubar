# Tests of the SwiftBar plugin, plugins/jenkins.30s.sh. Run them with tests/run.sh.

# ── Setup and tokens ──

test_plugin_asks_for_the_team_config() {
	: >"$tool/config/team.conf"
	plugin_run
	assert_equals "$(menubar)" 'CI ⚠️'
	assert_contains "$menu" 'Fill in the team settings'
	assert_contains "$menu" "Open the team settings… | $(opens_settings team)"
}

test_plugin_reads_a_quoted_token_with_a_comment_from_zshrc() {
	local auth=$JENKINS_MCP_BASIC_AUTH
	unset JENKINS_MCP_BASIC_AUTH
	printf 'export JENKINS_MCP_BASIC_AUTH="%s"  # the work Jenkins\n' "$auth" >"$HOME/.zshrc"
	jenkins_jobs MR-1:me
	jenkins_build MR-1 7 false SUCCESS 'Fix the login'
	plugin_run
	assert_contains "$(cat "$FAKE_CURL/headers")" "Authorization: Basic $auth" 'the sent headers'
	assert_contains "$menu" '✅ Fix the login'
}

test_plugin_skips_a_computed_token_in_zshrc_and_reads_the_keychain() {
	local auth=$JENKINS_MCP_BASIC_AUTH
	unset JENKINS_MCP_BASIC_AUTH
	echo 'export JENKINS_MCP_BASIC_AUTH=$(security find-generic-password -s jenkins -w)' >"$HOME/.zshrc"
	jenkins_jobs MR-1:me
	jenkins_build MR-1 7 false SUCCESS 'Fix the login'
	plugin_run
	assert_contains "$menu" 'No Jenkins token'
	assert_not_contains "$(cat "$FAKE_CURL/headers" 2>/dev/null)" 'security' 'the sent headers'

	printf '%s' "$auth" >"$FAKE_KEYCHAIN/jenkins-menubar.JENKINS_MCP_BASIC_AUTH"
	plugin_run
	assert_contains "$(cat "$FAKE_CURL/headers")" "Authorization: Basic $auth" 'the sent headers'
	assert_contains "$menu" '✅ Fix the login'
}

test_plugin_keeps_the_tokens_off_the_command_line() {
	export GITLAB_TOKEN=glpat-secret
	gitlab_answers me
	jenkins_jobs MR-1:me
	jenkins_build MR-1 7 false SUCCESS
	plugin_run
	assert_not_contains "$(cat "$FAKE_CURL/argv")" "$JENKINS_MCP_BASIC_AUTH" 'the curl command lines'
	assert_not_contains "$(cat "$FAKE_CURL/argv")" glpat-secret 'the curl command lines'
	assert_contains "$(cat "$FAKE_CURL/headers")" "Authorization: Basic $JENKINS_MCP_BASIC_AUTH" 'the sent headers'
	assert_contains "$(cat "$FAKE_CURL/headers")" 'Authorization: Bearer glpat-secret' 'the sent headers'
}

# ── Jenkins builds ──

test_plugin_shows_the_running_builds_of_my_merge_requests() {
	jenkins_jobs MR-1:me MR-2:someone-else
	jenkins_build MR-1 7 true null 'Fix the login'
	jenkins_stages MR-1 7 build:SUCCESS integration-tests:IN_PROGRESS
	plugin_run
	assert_equals "$(menubar)" ':hourglass:1 | emojize=false' 'menubar'
	assert_contains "$menu" '⏳ Fix the login'
	assert_contains "$menu" '▶ integration-tests'
	assert_contains "$menu" "href=$JOB_ROOT/job/MR-1/7/"
	assert_equals "$(request_count /job/MR-2/)" 0 'requests for the build of someone else'
}

test_plugin_shows_the_job_name_for_a_build_without_a_title() {
	jenkins_jobs MR-1:me
	jenkins_build MR-1 7 false SUCCESS ''
	plugin_run
	assert_contains "$menu" '✅ MR-1'
	assert_contains "$menu" '--SUCCESS · 0h30m · finished 30m ago'
	assert_contains "$menu" '--🦊 Open merge request !1 in GitLab | href=https://gitlab.test/group/project/-/merge_requests/1'
}

test_plugin_finds_my_jobs_by_my_gitlab_username() {
	JENKINS_MCP_BASIC_AUTH=$(printf 'jdoe:jenkins-secret' | base64)
	export GITLAB_TOKEN=glpat-secret
	gitlab_answers john.doe
	jenkins_jobs MR-1:john.doe
	jenkins_build MR-1 7 false SUCCESS 'Mine'
	plugin_run
	plugin_run
	assert_contains "$menu" '✅ Mine'
}

test_plugin_names_the_user_when_jenkins_has_no_builds_of_theirs() {
	jenkins_jobs MR-1:someone-else
	plugin_run
	assert_contains "$menu" 'No merge request builds by me in Jenkins'
}

test_plugin_alerts_when_a_build_it_saw_running_finishes() {
	jenkins_jobs MR-1:me
	jenkins_build MR-1 7 true null
	plugin_run
	jenkins_build MR-1 7 false SUCCESS
	plugin_run
	wait_for_call jenkins-watch
	assert_equals "$(calls jenkins-watch)" "jenkins-watch"$'\t'"$JOB_ROOT/job/MR-1/7/"
	assert_equals "$(menubar)" ':checkmark.circle:1 | emojize=false' 'menubar'
}

test_plugin_does_not_alert_for_a_build_that_was_already_finished() {
	jenkins_jobs MR-1:me
	jenkins_build MR-1 7 false FAILURE
	plugin_run
	plugin_run
	assert_no_call jenkins-watch
}

test_plugin_shows_a_banner_once_when_a_stage_fails() {
	jenkins_jobs MR-1:me
	jenkins_build MR-1 7 true null
	jenkins_stages MR-1 7 build:IN_PROGRESS
	plugin_run
	jenkins_stages MR-1 7 build:FAILED tests:IN_PROGRESS
	plugin_run
	plugin_run
	assert_equals "$(call_count jenkins-notifier)" 1 'stage banners'
	assert_contains "$(calls jenkins-notifier)" '💥 !1 #7: stage failed'
}

test_plugin_does_not_repeat_a_stage_banner_when_the_stages_request_fails() {
	jenkins_jobs MR-1:me
	jenkins_build MR-1 7 true null
	jenkins_stages MR-1 7 build:IN_PROGRESS
	plugin_run
	jenkins_stages MR-1 7 build:FAILED
	plugin_run
	route /job/MR-1/7/wfapi/describe 500
	plugin_run
	jenkins_stages MR-1 7 build:FAILED
	plugin_run
	assert_equals "$(call_count jenkins-notifier)" 1 'stage banners'
}

test_plugin_asks_for_the_stages_of_a_finished_build_only_once() {
	jenkins_jobs MR-1:me
	jenkins_build MR-1 7 false FAILURE
	jenkins_stages MR-1 7 build:SUCCESS tests:FAILED
	plugin_run
	assert_equals "$(request_count wfapi/describe)" 1 'stage requests on the first run'
	plugin_run
	assert_equals "$(request_count wfapi/describe)" 0 'stage requests on the second run'
	assert_contains "$menu" 'failed: tests'
}

test_plugin_hides_a_build_until_the_next_build_starts() {
	jenkins_jobs MR-1:me
	jenkins_build MR-1 7 false SUCCESS 'Fix the login'
	plugin_run
	plugin_action --hide MR-1 7
	plugin_render
	assert_not_contains "$menu" '✅ Fix the login'
	assert_contains "$menu" 'Show 1 hidden build'

	jenkins_build MR-1 8 true null 'Fix the login'
	jenkins_stages MR-1 8
	plugin_run
	assert_contains "$menu" '⏳ Fix the login'
	assert_not_contains "$menu" 'hidden build'
}

# ── When Jenkins does not answer ──

test_plugin_keeps_a_build_in_the_menu_while_jenkins_fails_for_its_job() {
	jenkins_jobs MR-1:me MR-2:me
	jenkins_build MR-1 7 false SUCCESS 'First'
	jenkins_build MR-2 3 false SUCCESS 'Second'
	plugin_run
	route /job/MR-2/api/json 500
	plugin_run
	assert_contains "$menu" '✅ First'
	assert_contains "$menu" '✅ Second'
}

test_plugin_keeps_a_hidden_build_hidden_while_jenkins_fails_for_its_job() {
	jenkins_jobs MR-1:me MR-2:me
	jenkins_build MR-1 7 false SUCCESS 'First'
	jenkins_build MR-2 3 false SUCCESS 'Second'
	plugin_run
	plugin_action --hide MR-1 7
	route /job/MR-1/api/json 500
	plugin_run
	assert_contains "$menu" 'Show 1 hidden build'

	jenkins_build MR-1 7 false SUCCESS 'First'
	plugin_run
	assert_not_contains "$menu" '✅ First'
	assert_contains "$menu" 'Show 1 hidden build'
}

test_plugin_stops_asking_jenkins_once_it_is_unreachable() {
	jenkins_jobs MR-1:me MR-2:me MR-3:me
	jenkins_build MR-1 1 false SUCCESS 'First'
	jenkins_build MR-2 2 false SUCCESS 'Second'
	jenkins_build MR-3 3 false SUCCESS 'Third'
	plugin_run
	route jenkins.test exit:28
	plugin_run
	assert_equals "$(request_count jenkins.test)" 1 'requests to Jenkins'
	assert_contains "$(cat "$FAKE_CURL/argv")" '--connect-timeout' 'the curl command lines'
	assert_contains "$menu" 'Jenkins unreachable (VPN?)'
	assert_contains "$menu" '✅ Second'
}

test_plugin_does_not_ask_for_the_builds_when_the_job_list_is_unreachable() {
	jenkins_jobs MR-1:me MR-2:me
	jenkins_build MR-1 1 false SUCCESS 'First'
	jenkins_build MR-2 2 false SUCCESS 'Second'
	plugin_run
	plugin_action --check-now
	route jenkins.test exit:7
	plugin_run
	assert_equals "$(request_count jenkins.test)" 1 'requests to Jenkins'
	assert_contains "$menu" 'Jenkins unreachable (VPN?)'
	assert_contains "$menu" '✅ First'
}

test_plugin_tells_when_jenkins_rejects_the_token() {
	route 'tree=jobs' 401
	plugin_run
	assert_contains "$menu" $'---\nJenkins rejected the token | color=red'
	assert_not_contains "$menu" 'unreachable'
}

test_plugin_tells_when_jenkins_rejects_the_token_for_the_builds() {
	jenkins_jobs MR-1:me
	jenkins_build MR-1 7 false SUCCESS 'Fix the login'
	plugin_run
	route jenkins.test 401
	plugin_run
	assert_contains "$menu" 'Jenkins rejected the token | color=red'
	assert_contains "$menu" '✅ Fix the login'
}

test_plugin_tells_when_jenkins_does_not_know_the_job() {
	route 'tree=jobs' 404
	plugin_run
	assert_contains "$menu" 'Jenkins does not know the job: check the job URL in Team | color=red'
}

test_plugin_drops_the_build_of_a_job_jenkins_no_longer_has() {
	jenkins_jobs MR-1:me
	jenkins_build MR-1 7 false SUCCESS 'Fix the login'
	plugin_run
	route /job/MR-1/ 404
	plugin_run
	assert_not_contains "$menu" 'Fix the login'
	assert_not_contains "$menu" 'color=red'
	assert_contains "$menu" 'No builds to show'
}

test_plugin_asks_for_the_builds_when_the_job_list_is_too_slow() {
	jenkins_jobs MR-1:me
	jenkins_build MR-1 7 true null 'Fix the login'
	jenkins_stages MR-1 7
	plugin_run
	plugin_action --check-now
	route 'tree=jobs' exit:28
	jenkins_build MR-1 7 false SUCCESS 'Fix the login'
	plugin_run
	assert_contains "$(cat "$FAKE_CURL/argv")" '--max-time 60' 'the curl command lines'
	assert_contains "$menu" '✅ Fix the login'
	assert_not_contains "$menu" 'unreachable'
	plugin_run
	assert_equals "$(request_count tree=jobs)" 0 'job list requests right after one was too slow'
}

test_plugin_only_renders_while_another_run_polls() {
	jenkins_jobs MR-1:me
	jenkins_build MR-1 7 false SUCCESS 'Fix the login'
	plugin_run
	echo $$ >"$cache/poll.lock"
	plugin_run
	assert_equals "$(request_count jenkins.test)" 0 'requests to Jenkins while another run polls'
	assert_contains "$menu" '✅ Fix the login'
	assert_equals "$(cat "$cache/poll.lock")" $$ 'the lock of the other run'
}

test_plugin_polls_when_the_run_that_held_the_lock_is_gone() {
	jenkins_jobs MR-1:me
	jenkins_build MR-1 7 false SUCCESS 'Fix the login'
	mkdir -p "$cache"
	(exit 0) &
	wait $!
	echo $! >"$cache/poll.lock"
	plugin_run
	assert_contains "$menu" '✅ Fix the login'
	[[ ! -e $cache/poll.lock ]] || fail 'expected the run to release the lock'
}

test_plugin_hides_finished_builds_immediately_when_set() {
	jenkins_jobs MR-1:me MR-2:me MR-3:me
	jenkins_build MR-1 7 false SUCCESS 'Green'
	jenkins_build MR-2 3 false FAILURE 'Red'
	jenkins_build MR-3 5 true null 'Running'
	jenkins_stages MR-3 5
	plugin_action --set hide_successful_after_hours immediately
	plugin_run
	assert_not_contains "$menu" '✅ Green'
	assert_contains "$menu" '❌ Red'
	assert_contains "$menu" '⏳ Running'
	assert_equals "$(plugin_json .settings.hide_successful_after_hours)" immediately 'hide_successful_after_hours'

	plugin_action --set hide_failed_after_hours immediately
	plugin_render
	assert_not_contains "$menu" '❌ Red'
	assert_contains "$menu" '⏳ Running'
	assert_not_contains "$menu" 'Hide all finished builds'
}

# ── Settings and the settings window ──

test_plugin_settings_item_opens_the_settings_window() {
	plugin_run
	assert_contains "$menu" $'\n'"Settings… | $(opens_settings jenkins)"
}

test_plugin_settings_item_opens_the_settings_file_without_the_app() {
	rm "$tool/notifier/Jenkins Watch.app/Contents/MacOS/jenkins-notifier"
	plugin_run
	assert_contains "$menu" "Settings… | bash=/usr/bin/open param1=-t param2=\"$tool/config/settings\" terminal=false"
}

test_plugin_previews_the_alert_the_settings_choose() {
	plugin_action --preview-success
	assert_equals "$(calls jenkins-watch)" "jenkins-watch"$'\t'"--test" 'the preview with the big alert'
	: >"$CALLS"
	plugin_action --set alert banner
	plugin_action --set voice on
	plugin_action --preview-failure
	assert_equals "$(calls jenkins-watch)" "jenkins-watch"$'\t'"--test-failure"$'\t'"--voice"$'\t'"--banner" 'the preview with the banner'
}

test_plugin_settings_json_has_the_defaults_and_the_set_values() {
	plugin_action --set refresh_seconds 300
	plugin_action --set hide_successful_after_hours soon
	assert_contains "$(cat "$tool/config/settings")" $'\nrefresh_seconds=300\n' 'the settings file'
	assert_equals "$(plugin_json .settings.refresh_seconds)" 300 'refresh_seconds'
	assert_equals "$(plugin_json .settings.hide_successful_after_hours)" 24 'hide_successful_after_hours, not a number'
	assert_equals "$(plugin_json .settings.alert)" dialog 'alert'
	assert_equals "$(plugin_json .team.gitlab_project)" group/project 'gitlab_project'
	assert_equals "$(plugin_json .files.settings)" "$tool/config/settings" 'the settings file'
	assert_equals "$(plugin_json .links.jenkinsToken)" https://jenkins.test/me/ 'the Jenkins token page'
}

test_plugin_set_team_writes_the_team_config() {
	plugin_action --set-team committed_label 'workflow::committed'
	assert_contains "$(cat "$tool/config/team.conf")" $'\ncommitted_label=workflow::committed' 'team.conf'
	assert_equals "$(plugin_json .team.committed_label)" 'workflow::committed' 'committed_label'
}

test_plugin_work_items_menu_sums_up_the_filters() {
	export GITLAB_TOKEN=glpat-secret
	gitlab_answers me
	plugin_action --set work_items_scope authored
	plugin_action --set work_items_state all
	plugin_action --label-filter 'type::bug' with
	plugin_action --label-filter 'workflow::done' without
	plugin_run
	assert_contains "$menu" '--Created by me · Open and closed · +bug · −done | size=12 color=#8E8E93'
	assert_contains "$menu" "--Filters… | $(opens_settings gitlab)"
}

test_plugin_label_filter_puts_a_label_in_one_list() {
	plugin_action --label-filter 'type::bug' with
	plugin_action --label-filter 'workflow::done' without
	assert_equals "$(plugin_json .settings.work_items_with_labels)" 'type::bug' 'with'
	assert_equals "$(plugin_json .settings.work_items_without_labels)" 'workflow::done' 'without'
	plugin_action --label-filter 'type::bug' without
	assert_equals "$(plugin_json .settings.work_items_with_labels)" '' 'with'
	assert_equals "$(plugin_json .settings.work_items_without_labels)" 'workflow::done,type::bug' 'without'
	plugin_action --label-filter 'workflow::done' any
	assert_equals "$(plugin_json .settings.work_items_without_labels)" 'type::bug' 'without'
	assert_equals "$(plugin_json '.labels | join(",")')" 'type::bug' 'offered labels'
}

test_plugin_keeps_one_must_have_label_per_scope() {
	plugin_action --label-filter uStatus::Todo with
	plugin_action --label-filter uStatus::Done without
	plugin_action --label-filter uStatus::Sub::Deep with
	plugin_action --label-filter uStatus::InProgress with
	plugin_action --label-filter bug with
	assert_equals "$(plugin_json .settings.work_items_with_labels)" 'uStatus::Sub::Deep,uStatus::InProgress,bug' 'with'
	assert_equals "$(plugin_json .settings.work_items_without_labels)" 'uStatus::Done' 'without'
}

# ── Tokens and accounts in the settings window ──

test_plugin_settings_json_tells_where_the_tokens_come_from() {
	assert_equals "$(plugin_json .tokens.jenkins.source)" environment 'Jenkins token'
	assert_equals "$(plugin_json .tokens.jenkins.user)" me 'Jenkins user'
	assert_equals "$(plugin_json .tokens.gitlab.source)" none 'GitLab token'
	unset JENKINS_MCP_BASIC_AUTH
	echo 'export GITLAB_TOKEN=$(security find-generic-password -s gitlab -w)' >"$HOME/.zshrc"
	assert_equals "$(plugin_json .tokens.jenkins.source)" none 'Jenkins token'
	assert_equals "$(plugin_json .tokens.gitlab.source)" zshrc-computed 'GitLab token'
	echo 'export GITLAB_TOKEN=glpat-plain' >"$HOME/.zshrc"
	assert_equals "$(plugin_json .tokens.gitlab.source)" zshrc 'GitLab token'
	printf 'glpat-stored' >"$FAKE_KEYCHAIN/jenkins-menubar.GITLAB_TOKEN"
	assert_equals "$(plugin_json .tokens.gitlab.source)" keychain 'GitLab token'
}

test_plugin_stores_a_token_in_the_keychain_without_a_command_line_showing_it() {
	printf 'glpat-New_token-123' | plugin_action --set-token GITLAB_TOKEN
	assert_equals "$(cat "$FAKE_KEYCHAIN/jenkins-menubar.GITLAB_TOKEN")" glpat-New_token-123 'the token in the keychain'
	assert_not_contains "$(cat "$FAKE_KEYCHAIN/argv")" glpat-New_token-123 'the security command lines'
	assert_equals "$(plugin_json .tokens.gitlab.source)" keychain 'GitLab token'
	plugin_action --delete-token GITLAB_TOKEN
	assert_equals "$(plugin_json .tokens.gitlab.source)" none 'GitLab token after deleting it'
}

test_plugin_refuses_a_token_with_spaces() {
	local status
	printf 'not a token' | plugin_action --set-token GITLAB_TOKEN
	status=$?
	assert_equals "$status" 2 'exit status'
	assert_equals "$(plugin_json .tokens.gitlab.source)" none 'GitLab token'
}

test_plugin_checks_the_accounts() {
	export GITLAB_TOKEN=glpat-secret
	route 'tree=name' 200 '{"name": "project"}'
	gitlab_answers john.doe
	local result
	result=$("$tool/plugins/jenkins.30s.sh" --check-accounts 2>>"$sandbox/stderr")
	assert_equals "$(jq -r '"\(.jenkins.ok) \(.jenkins.message)"' <<<"$result")" 'true Signed in as me' 'Jenkins'
	assert_equals "$(jq -r '"\(.gitlab.ok) \(.gitlab.message)"' <<<"$result")" 'true Signed in as john.doe' 'GitLab'
}

test_plugin_account_check_tells_what_is_wrong() {
	export GITLAB_TOKEN=glpat-expired
	route 'tree=name' 401
	route currentUser exit:7
	local result
	result=$("$tool/plugins/jenkins.30s.sh" --check-accounts 2>>"$sandbox/stderr")
	assert_equals "$(jq -r '"\(.jenkins.ok) \(.jenkins.message)"' <<<"$result")" 'false Jenkins rejected the token' 'Jenkins'
	assert_equals "$(jq -r '"\(.gitlab.ok) \(.gitlab.message)"' <<<"$result")" 'false GitLab unreachable' 'GitLab'
	unset GITLAB_TOKEN
	result=$("$tool/plugins/jenkins.30s.sh" --check-accounts 2>>"$sandbox/stderr")
	assert_equals "$(jq -r '"\(.gitlab.ok) \(.gitlab.message)"' <<<"$result")" 'false No token yet' 'GitLab'
}

# ── GitLab ──

test_plugin_explains_the_gitlab_token_when_there_is_none() {
	plugin_run
	assert_contains "$menu" '--Needs a GitLab token with the read_api scope'
	assert_contains "$menu" "--2. Paste it in Settings… → Accounts | $(opens_settings accounts)"
}

test_plugin_reports_a_rejected_gitlab_token() {
	export GITLAB_TOKEN=glpat-expired
	route currentUser 401 '{"message": "401 Unauthorized"}'
	plugin_run
	assert_contains "$menu" 'GitLab merge requests ⚠️'
	assert_contains "$menu" 'GitLab rejected the token'
}

test_plugin_reports_a_gitlab_token_without_the_read_api_scope() {
	export GITLAB_TOKEN=glpat-no-scope
	route currentUser 403 '{"error": "insufficient_scope"}'
	plugin_run
	assert_contains "$menu" 'GitLab rejected the token (expired, or without the read_api scope?)'
}

test_plugin_lists_my_merge_requests_and_the_reviews_asked_of_me() {
	export GITLAB_TOKEN=glpat-secret
	gitlab_answers me "$(gitlab_merge_request 1 'My change' me NOT_APPROVED)" "$(gitlab_merge_request 2 'Their change' someone MERGEABLE me)"
	plugin_run
	assert_contains "$menu" 'GitLab merge requests · 1 open · 1 to review'
	assert_contains "$menu" '--:hourglass.circle.fill: My change | href=https://gitlab.test/group/project/-/merge_requests/1 sfcolor=#737278,#A4A3A8 tooltip="!1 · No reviewers yet'
	assert_contains "$menu" '--:eye.circle.fill: Their change | href=https://gitlab.test/group/project/-/merge_requests/2 sfcolor=#C17D10,#D99530 tooltip="!2 · Review requested · Ready to merge · by someone'
}

# assert_label_offered <label>: the label filters of the settings window offer the label.
assert_label_offered() {
	plugin_json '.labels[]' | grep -qxF -- "$1" || fail "expected the label filters to offer $1" "--- offered:" "$(plugin_json '.labels[]')"
}

assert_label_not_offered() {
	! plugin_json '.labels[]' | grep -qxF -- "$1" || fail "expected the label filters not to offer $1" "--- offered:" "$(plugin_json '.labels[]')"
}

test_plugin_drops_the_labels_no_work_item_had_for_30_days() {
	export GITLAB_TOKEN=glpat-secret
	gitlab_answers me
	gitlab_work_item_with_labels type::bug
	mkdir -p "$cache"
	jq -n --argjson now "$(date +%s)" '{"old::label": ($now - 31 * 86400), "recent::label": ($now - 86400)}' >"$cache/work-item-labels.json"
	plugin_run
	assert_label_offered type::bug
	assert_label_offered recent::label
	assert_label_not_offered old::label
}

test_plugin_keeps_offering_the_labels_of_an_old_label_list() {
	export GITLAB_TOKEN=glpat-secret
	gitlab_answers me
	gitlab_work_item_with_labels type::bug
	mkdir -p "$cache"
	echo '["legacy::label"]' >"$cache/work-item-labels.json"
	plugin_run
	assert_label_offered legacy::label
	assert_label_offered type::bug
}

test_plugin_keeps_a_slot_label_from_adding_menu_parameters() {
	export GITLAB_TOKEN=glpat-secret
	plugin_action --set-team slot_label_prefix 'slot::'
	gitlab_answers me
	gitlab_work_item_with_labels $'slot::Q1 | bash=/usr/bin/touch param1=pwned\nInjected | bash=/usr/bin/touch'
	plugin_run
	assert_contains "$menu" '--#1  Q1 ¦ bash=/usr/bin/touch param1=pwned Injected ¦ bash=/usr/bin/touch · Item | href=https://gitlab.test/group/project/-/issues/1'
	assert_not_contains "$menu" $'\nInjected' 'the menu'
}

test_plugin_keeps_a_label_with_shell_syntax_as_plain_text() {
	export GITLAB_TOKEN=glpat-secret
	gitlab_answers me
	gitlab_work_item_with_labels 'evil::$(touch pwned)' type::bug
	plugin_run
	assert_label_offered 'evil::$(touch pwned)'
	assert_not_contains "$menu" 'pwned' 'the menu'
	(cd "$sandbox" && plugin_action --label-filter 'evil::$(touch pwned)' with && plugin_run)
	assert_equals "$(plugin_json .settings.work_items_with_labels)" 'evil::$(touch pwned)' 'with'
	[[ ! -e $sandbox/pwned && ! -e $tool/pwned ]] || fail 'a label ran as a command'
}

# gitlab_labels <title> …: GitLab's answer to every label search, the labels in GitLab's default blue.
gitlab_labels() {
	route includeAncestorGroups 200 "$(jq -n '{data: {project: {labels: {nodes: [$ARGS.positional[] | {title: ., color: "#428bca"}]}}}}' --args "$@")"
}

# gitlab_variables <text in the query>: the variables of the last GitLab request with that query.
gitlab_variables() {
	requests | grep -F -- "$1" | tail -n 1 | cut -f 2- | jq -c .variables
}

test_plugin_searches_the_labels_of_gitlab_and_of_my_work_items() {
	export GITLAB_TOKEN=glpat-secret
	mkdir -p "$cache"
	jq -n --argjson now "$(date +%s)" '{"uStatus::Seen": $now, "bug": $now}' >"$cache/work-item-labels.json"
	# GitLab also finds Answered by its description.
	route includeAncestorGroups 200 '{"data": {"project": {"labels": {"nodes": [
		{"title": "uStatus::Todo", "color": "#9400d3"}, {"title": "Answered", "color": "#808080"}]}}}}'
	local result
	result=$("$tool/plugins/jenkins.30s.sh" --search-labels STATUS 2>>"$sandbox/stderr")
	assert_equals "$(jq -c . <<<"$result")" '{"labels":["uStatus::Seen","uStatus::Todo"],"colors":{"uStatus::Todo":"#9400d3"},"problem":null}' \
		'the labels found'
}

test_plugin_searches_only_the_labels_of_my_work_items_without_gitlab() {
	mkdir -p "$cache"
	echo '["uStatus::Seen", "bug"]' >"$cache/work-item-labels.json"
	local result
	result=$("$tool/plugins/jenkins.30s.sh" --search-labels status 2>>"$sandbox/stderr")
	assert_equals "$(jq -c .labels <<<"$result")" '["uStatus::Seen"]' 'the labels found'
	assert_contains "$(jq -r .problem <<<"$result")" 'No GitLab token' 'the problem'
	export GITLAB_TOKEN=glpat-secret
	route includeAncestorGroups exit:7
	result=$("$tool/plugins/jenkins.30s.sh" --search-labels status 2>>"$sandbox/stderr")
	assert_equals "$(jq -c .labels <<<"$result")" '["uStatus::Seen"]' 'the labels found while GitLab is unreachable'
	assert_contains "$(jq -r .problem <<<"$result")" 'GitLab did not answer' 'the problem'
}

test_plugin_flags_a_filter_label_gitlab_no_longer_has() {
	export GITLAB_TOKEN=glpat-secret
	gitlab_answers me
	gitlab_labels uStatus::Done
	plugin_action --label-filter uStatus::Done without
	plugin_action --label-filter uStatus::Gone without
	plugin_run
	assert_equals "$(plugin_json '.missingLabels | join(",")')" 'uStatus::Gone' 'missing labels'
	assert_equals "$(plugin_json '.labelColors | tojson')" '{"uStatus::Done":"#428bca"}' 'the colors of the filter labels'
	assert_contains "$menu" "--⚠️ Filter label uStatus::Gone is not in GitLab any more | color=red $(opens_settings gitlab)"
	plugin_action --label-filter uStatus::Gone any
	assert_equals "$(plugin_json '.missingLabels | length')" 0 'missing labels once it is out of the filter'
	plugin_render
	assert_not_contains "$menu" 'not in GitLab any more'
}

test_plugin_asks_gitlab_for_all_or_any_of_the_must_have_labels() {
	export GITLAB_TOKEN=glpat-secret
	plugin_action --set-team committed_label Committed
	gitlab_answers me
	plugin_action --label-filter type::bug with
	plugin_action --label-filter team::web with
	plugin_run
	assert_equals "$(gitlab_variables withCommitted | jq -c '[.committedLabels, .committedOr, .otherLabels, .otherOr]')" \
		'[["Committed","team::web","type::bug"],null,["type::bug","team::web"],null]' 'all of the labels'
	plugin_action --label-match any
	plugin_run
	assert_equals "$(gitlab_variables withCommitted | jq -c '[.committedLabels, .committedOr, .otherLabels, .otherOr]')" \
		'[["Committed"],{"labelNames":["type::bug","team::web"]},null,{"labelNames":["type::bug","team::web"]}]' 'any of the labels'
	assert_contains "$menu" '· +(bug or web) |'
}

test_plugin_keeps_several_labels_of_a_scope_for_any_of_them() {
	plugin_action --label-match any
	plugin_action --label-filter uStatus::Todo with
	plugin_action --label-filter uStatus::InProgress with
	plugin_action --label-filter bug with
	assert_equals "$(plugin_json .settings.work_items_with_labels)" 'uStatus::Todo,uStatus::InProgress,bug' 'with, any of them'
	plugin_action --label-match all
	assert_equals "$(plugin_json .settings.work_items_labels_match)" all 'match'
	assert_equals "$(plugin_json .settings.work_items_with_labels)" 'uStatus::InProgress,bug' 'with, all of them'
}

test_plugin_shows_the_work_items_with_a_broken_related_merge_requests_file() {
	export GITLAB_TOKEN=glpat-secret
	gitlab_answers me
	gitlab_work_item_with_labels type::bug
	plugin_run
	# Half written, like while another run polls.
	mkdir -p "$cache/related-merge-requests"
	printf '{"reference": "group/pro' >"$cache/related-merge-requests/half.json"
	plugin_render
	assert_contains "$menu" $'\n--#1  Item | href=https://gitlab.test/group/project/-/issues/1'
}

# SwiftBar 2.1.0 and 2.1.1 grey out an item with a submenu but no action for good once its line changes
# (swiftbar/SwiftBar#512).
test_plugin_gives_every_item_with_a_submenu_an_action() {
	export GITLAB_TOKEN=glpat-secret
	gitlab_answers me "$(gitlab_merge_request 1 'My change' me NOT_APPROVED)"
	jenkins_jobs MR-1:me
	jenkins_build MR-1 7 true null 'Fix the login'
	jenkins_stages MR-1 7
	plugin_run
	local parents
	parents=$(printf '%s\n' "$menu" | awk '/^--/ && $0 != "---" && previous != "" && previous != "---" && previous !~ /^--/ { print previous }
		{ previous = $0 }' | sed -E 's/ image=[^ ]+//')
	assert_contains "$parents" $'⏳ Fix the login | href=https://jenkins.test/job/project/job/MR-1/7/\n'
	assert_contains "$parents" $'GitLab merge requests · 1 open | href=https://gitlab.test/dashboard/merge_requests\n'
	assert_contains "$parents" 'GitLab work items (0) | href=https://gitlab.test/dashboard/issues?assignee_username=me&state=opened'
	assert_equals "$(printf '%s\n' "$parents" | grep -vc ' | href=')" 0 'items with a submenu but no action'
}
