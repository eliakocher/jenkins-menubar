# Tests of bin/jenkins-watch. Run them with tests/run.sh.

# run_watch <arguments>: the output ends up in $output, the exit status in $status.
run_watch() {
	output=$("$tool/bin/jenkins-watch" "$@" 2>&1)
	status=$?
}

test_watch_prints_its_help() {
	run_watch --help
	assert_equals "$status" 0 'exit status'
	assert_contains "$output" 'Usage: jenkins-watch'
}

test_watch_rejects_a_target_it_does_not_understand() {
	run_watch 'not a target'
	assert_equals "$status" 2 'exit status'
	assert_contains "$output" "expected an MR number or a Jenkins URL, got 'not a target'"
}

test_watch_gives_up_when_jenkins_does_not_know_the_job() {
	run_watch 404
	assert_equals "$status" 2 'exit status'
	assert_contains "$output" "HTTP 404 for $JOB_ROOT/job/MR-404/api/json"
}

test_watch_watches_the_last_build_of_an_mr_number() {
	jenkins_build MR-12 4 false SUCCESS
	run_watch --banner '!12'
	assert_equals "$status" 0 'exit status'
	assert_contains "$output" "Watching MR-12 #4"
	assert_contains "$output" 'MR-12 #4 finished: SUCCESS'
}

test_watch_announces_a_successful_build_with_a_banner() {
	jenkins_build MR-1 7 false SUCCESS
	run_watch --banner "$JOB_ROOT/job/MR-1/7/console"
	assert_equals "$status" 0 'exit status'
	assert_contains "$(calls jenkins-notifier)" $'--title\t✅ MR-1 #7 SUCCESS\t--body\tDuration: 0h30m'
	assert_contains "$(calls jenkins-notifier)" $'--mr\thttps://gitlab.test/group/project/-/merge_requests/1\t--default\tmr'
	assert_equals "$(call_count osascript)" 0 'dialogs'
	assert_equals "$(call_count say)" 0 'spoken results'
}

test_watch_exits_1_and_lists_the_failed_stages_of_a_failed_build() {
	jenkins_build MR-1 7 false FAILURE
	jenkins_stages MR-1 7 build:SUCCESS tests:FAILED
	run_watch --banner --voice "$JOB_ROOT/job/MR-1/7/"
	assert_equals "$status" 1 'exit status'
	assert_contains "$(calls jenkins-notifier)" $'--title\t❌ MR-1 #7 FAILURE\t--body\tDuration: 0h30m\\nFailed stages: tests'
	assert_contains "$(calls jenkins-notifier)" $'--default\tbuild'
	assert_contains "$(calls say)" 'Jenkins build failed'
}

test_watch_shows_a_dialog_and_no_banner_unless_asked_for_a_banner() {
	jenkins_build MR-1 7 false SUCCESS
	run_watch "$JOB_ROOT/job/MR-1/7/"
	assert_contains "$(calls osascript)" $'osascript\t-l\tJavaScript\t-\t✅ MR-1 #7 SUCCESS'
	assert_equals "$(call_count jenkins-notifier)" 0 'banners'
}

test_watch_follows_the_newer_build_when_its_build_was_aborted() {
	jenkins_build MR-1 7 false ABORTED
	jenkins_build MR-1 8 false SUCCESS
	run_watch --banner "$JOB_ROOT/job/MR-1/7/"
	assert_equals "$status" 0 'exit status'
	assert_contains "$output" '#7 was aborted, superseded by #8'
	assert_contains "$(calls jenkins-notifier)" $'--title\t✅ MR-1 #8 SUCCESS'
}

test_watch_keeps_the_token_off_the_command_line() {
	jenkins_build MR-1 7 false SUCCESS
	run_watch --banner "$JOB_ROOT/job/MR-1/7/"
	assert_not_contains "$(cat "$FAKE_CURL/argv")" "$JENKINS_MCP_BASIC_AUTH" 'the curl command lines'
	assert_contains "$(cat "$FAKE_CURL/headers")" "Authorization: Basic $JENKINS_MCP_BASIC_AUTH" 'the sent headers'
}

test_watch_reads_the_token_from_the_keychain() {
	local auth=$JENKINS_MCP_BASIC_AUTH
	unset JENKINS_MCP_BASIC_AUTH
	printf '%s' "$auth" >"$FAKE_KEYCHAIN/jenkins-menubar.JENKINS_MCP_BASIC_AUTH"
	jenkins_build MR-1 7 false SUCCESS
	run_watch --banner "$JOB_ROOT/job/MR-1/7/"
	assert_equals "$status" 0 'exit status'
	assert_contains "$(cat "$FAKE_CURL/headers")" "Authorization: Basic $auth" 'the sent headers'
}
