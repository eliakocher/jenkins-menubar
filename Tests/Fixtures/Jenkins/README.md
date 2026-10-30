# Jenkins fixtures

Answers of Jenkins for the tests of `JenkinsClient`, `WatchTarget` and `JenkinsCheck`. Every name, title, host and
branch is made up: the hosts are `jenkins.example.com` and `gitlab.example.com`, the multibranch job is
`GitLab%20Team/job/team%252Fproduct`, the user is `jdoe`.

| File | Request | Source |
|---|---|---|
| `jobs.json` | `/api/json?tree=jobs[name,actions[contributor]]` | real, sanitized: 8 complete jobs of a capture cut at 128 KB (`_class` names and empty actions as Jenkins sent them) |
| `job-finished.json` | `/job/MR-1/api/json?tree=actions[…],lastBuild[…]` | real, sanitized: a finished SUCCESS build |
| `job-running.json` | same | `job-finished.json` with `building: true`, `result: null`, `duration: 0` |
| `job-without-build.json` | same | `job-finished.json` with `lastBuild: null` |
| `describe-running.json`, `describe-finished.json`, `describe-failed.json` | `/job/MR-1/7/wfapi/describe` | hand-written, in the format of the Pipeline Stage View plugin's REST API and the fields the old plugin read |
| `test-counts.json`, `test-counts-none.json` | `/job/MR-1/7/api/json?tree=actions[failCount,totalCount]` | hand-written, with the fields the old `jenkins-watch` read |
| `test-report.json` | `/job/MR-1/7/testReport/api/json?tree=suites[cases[className,name,status,errorDetails,age]]` | hand-written, in the format of the JUnit plugin's `TestResult`: PASSED, FAILED, REGRESSION, SKIPPED and FIXED cases, a multi-line and a missing error message, a case without a class or status, a suite without cases (PIPE-03) |
| `account.json` | `/api/json?tree=name` | hand-written |
| `error-401.html`, `error-404.html`, `error-500.html` | any | hand-written error pages |
| `build-parameters.json`, `build-without-parameters.json` | `/job/MR-1/7/api/json?tree=actions[parameters[name,value]]` | hand-written, in the format of Jenkins' `ParametersAction`: a string, a boolean, a password without a value, a run parameter (PIPE-09) |
| `job-parameter-definitions.json`, `job-without-parameter-definitions.json` | `/job/MR-1/api/json?tree=property[parameterDefinitions[name]]` | hand-written, in the format of `ParametersDefinitionProperty` (PIPE-09) |
| `queue-item-waiting.json`, `queue-item-started.json`, `queue-item-cancelled.json` | `/queue/item/42/api/json?tree=cancelled,executable[number]` | hand-written, with the fields of Jenkins' `Queue.Item` and `Queue.LeftItem` (PIPE-09) |
| `job-builds-history.json` | `/job/MR-1/api/json?tree=builds[number,result,building,actions[…]]{0,12}` | hand-written, in the format of the git plugin's `BuildData` (`marked`, `lastBuiltRevision`, `remoteUrls`, exported by `@Exported` getters; checked in the plugin's source): a running build, a build with a shared library's `BuildData` before the job's own, an upper-case SHA, an aborted build, a `marked` the map doesn't have, a build without a git action and a map of the wrong shape (PIPE-10) |
| `crumb.json`, `error-403-crumb.html`, `error-403-build-permission.html` | `/crumbIssuer/api/json`; a build request | hand-written: a crumb, the CSRF filter's 403 ("No valid crumb was included in the request") and a 403 for a missing Build permission (PIPE-09) |

The old tool's 1000 captured requests (`~/Library/Logs/jenkins-menubar/requests/`, 2026-10-28) held only the job list
and the job answers, all of them finished SUCCESS builds; nothing of `wfapi/describe`, the test counts or the account
check. The sanitizing script kept only bodies: the captured headers carry the user's login in base64.
