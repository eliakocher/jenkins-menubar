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
	assert_contains "$menu" '--My change | href=https://gitlab.test/group/project/-/merge_requests/1 tooltip="!1 · No reviewers yet'
	assert_contains "$menu" '--Their change | href=https://gitlab.test/group/project/-/merge_requests/2 tooltip="!2 · Review requested · Ready to merge · by someone'
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
