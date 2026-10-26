# Tests of the SwiftBar plugin, plugins/jenkins.30s.sh. Run them with tests/run.sh.

# ── Setup and tokens ──

test_plugin_asks_for_the_team_config() {
	: >"$tool/config/team.conf"
	plugin_run
	assert_equals "$(menubar)" 'CI ⚠️'
	assert_contains "$menu" 'Fill in config/team.conf'
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

# ── Settings ──

test_plugin_settings_menu_writes_the_settings_file() {
	plugin_action --set refresh_seconds 300
	assert_contains "$(cat "$tool/config/settings")" $'\nrefresh_seconds=300\n' 'the settings file'
	plugin_render
	assert_contains "$menu" '----5 minutes | bash='
	assert_contains "$menu" 'param2=refresh_seconds param3=300 terminal=false refresh=true checked=true'
}

# ── GitLab ──

test_plugin_explains_the_gitlab_token_when_there_is_none() {
	plugin_run
	assert_contains "$menu" '--Needs a GitLab token with the read_api scope'
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
	assert_contains "$menu" '--My change | href=https://gitlab.test/group/project/-/merge_requests/1 tooltip="!1 · No reviewers yet'
	assert_contains "$menu" '--Their change | href=https://gitlab.test/group/project/-/merge_requests/2 tooltip="!2 · Review requested · Ready to merge · by someone'
}

# assert_label_offered <label>: the "With labels" submenu has an item for the label.
assert_label_offered() {
	printf '%s\n' "$menu" | grep -F 'param2=with ' | grep -qF "param3=$(printf '%s' "$1" | base64) " ||
		fail "expected the label filters to offer $1" "--- menu:" "$menu"
}

assert_label_not_offered() {
	! printf '%s\n' "$menu" | grep -F 'param2=with ' | grep -qF "param3=$(printf '%s' "$1" | base64) " ||
		fail "expected the label filters not to offer $1" "--- menu:" "$menu"
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

test_plugin_label_filter_items_carry_no_shell_syntax() {
	export GITLAB_TOKEN=glpat-secret
	gitlab_answers me
	gitlab_work_item_with_labels 'evil::$(touch pwned)' type::bug
	plugin_run
	local params bug
	params=$(printf '%s\n' "$menu" | grep -F 'param1=--label' | grep -o 'param3=[^ ]*')
	assert_contains "$params" 'param3=' 'the label items'
	assert_equals "$(printf '%s\n' "$params" | grep -cvE '^param3=[A-Za-z0-9+/=]+$')" 0 'label parameters with other characters'

	bug=$(printf '%s\n' "$menu" | grep -F -- '--------bug |' | grep -F 'param2=with ' | grep -o 'param3=[^ ]*' | cut -d = -f 2-)
	plugin_action --label with "$bug"
	assert_contains "$(cat "$tool/config/settings")" $'\nwork_items_with_labels=type::bug\n' 'the settings file'
	plugin_action --label without "$bug"
	assert_contains "$(cat "$tool/config/settings")" $'\nwork_items_with_labels=\n' 'the settings file'
	assert_contains "$(cat "$tool/config/settings")" $'\nwork_items_without_labels=type::bug\n' 'the settings file'
}
