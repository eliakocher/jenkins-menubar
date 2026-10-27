# Jenkins & GitLab menubar

A macOS menubar menu (SwiftBar plugin) for a GitLab project that Jenkins builds with a multibranch job:

- **Your Jenkins MR pipelines** with live stage and ETA, and a big alert (or a banner) the moment one finishes
- **Your colleagues' builds** the same way: **Watch a Build…** takes a link to a Jenkins build (an MR's or a branch's
  like `develop`) or to a GitLab merge request, or `!123`
- **Your GitLab merge requests**: your own, review requested, reviewed, each with a status badge in GitLab's colors
  (ready to merge, approvals missing, review requested, pipeline failed, …), the details on hover
- **Your GitLab work items**: committed and not committed, with filters, label filters and sorting

<img src="docs/menubar.png" alt="The menu with a running and a finished MR pipeline, GitLab merge requests and work items" width="546">

## Install

1. Put this folder where it will stay (it runs from here).
2. Copy `config/team.example.conf` to `config/team.conf` and fill in your Jenkins job and GitLab project, or use the
   `team.conf` your team shares.
3. In Terminal: `./install.sh`
   It installs jq and SwiftBar through Homebrew if missing, needs the Xcode Command Line Tools
   (`xcode-select --install`) and makes SwiftBar start at login.
4. Add the two tokens if the script says they are missing: in the menu, **Settings… → Accounts** stores them in the
   login keychain and checks that Jenkins and GitLab take them. Plain exports in `~/.zshrc` work too:
   - `export JENKINS_MCP_BASIC_AUTH=<base64 of jenkins-user:api-token>`
   - `export GITLAB_TOKEN=<GitLab token with the read_api scope>`

   A `~/.zshrc` that computes them (like `$(security …)`) does not, since the menu cannot run it: use Accounts instead,
   or put them in the keychain yourself (each command asks for the value):
   ```
   security add-generic-password -U -s jenkins-menubar -a JENKINS_MCP_BASIC_AUTH -w
   security add-generic-password -U -s jenkins-menubar -a GITLAB_TOKEN -w
   ```
5. Click **Allow** when macOS asks whether "Jenkins" may send notifications.

**Settings…** in the menu opens the settings window: **Jenkins** (checking, hiding, alerts), **Watching** (the builds of
others, see below), **GitLab** (checking, the work item filters and labels; the work items submenu's **Filters…** opens
it too), **Accounts** (the tokens), **Team** (`config/team.conf`) and **Logs**. It writes `config/settings` and
`config/team.conf`, which you can also edit by hand.

**Logs** shows what the menu did, each entry with how it went (a green 200 or SUCCESS, a red TIMEOUT or FAILURE, …):
every request to Jenkins and GitLab with its time, the builds that started and finished, the alerts, the problems (once
when they start, once when they are resolved) and the setting changes, never a token. Search it, filter it by level
and source, copy entries. A double-click on a request (or its ⓘ) shows the request and the response, with the headers,
and copies it as a curl command; the tokens and the cookies are never kept. Above, **Check Times** charts how long the
checks of the last 24 hours took, their requests together, per hour, with the averages. The log starts a new file at
1 MB and keeps 4 old ones, the check times keep their newest half at 512 KB, the requests the newest 10 MB with the
first 128 KB of each response: together never more than 16.3 MB.

<img src="docs/settings.png" alt="The settings window at its Jenkins pane: check interval, when to hide finished builds, the alert and the menubar icons" width="600">

**Watch a Build…** in the menu opens **Watching** with the link you copied already in, Return watches it: all builds of
that merge request or branch, the next ones too, until Jenkins drops its job or you stop watching. Watched builds show
under **Watching** in the menu, with their author, and follow the same rules as yours: the same alerts, the same hiding.

`jenkins-watch <MR number | build URL>` watches a build from the terminal instead; `jenkins-watch --help` for more.

## What is where

| What | Where |
| --- | --- |
| SwiftBar plugin | `plugins/jenkins.30s.sh`, SwiftBar's plugin folder (or linked into yours) |
| Alert script | `bin/jenkins-watch`, linked as `~/bin/jenkins-watch` |
| App for the banners and the settings window | `notifier/Jenkins Watch.app`, built from `notifier/*.swift` |
| Tests | `tests/`, run with `tests/run.sh` |
| Icons | `icons/`: the app icon is `AppIcon.icon` (edit it in Icon Composer), `app.png` is its flat version for builds without Xcode |
| README screenshots | `docs/` |
| Team configuration (Jenkins, GitLab, label conventions) | `config/team.conf`, not committed |
| Your settings | `config/settings`, created on the first run, not committed |
| Cache | `~/Library/Caches/jenkins-menubar/` |
| Logs (also for Console.app) | `~/Library/Logs/jenkins-menubar/` |

## Tests

`tests/run.sh` runs the tests of the plugin and of `jenkins-watch`; `tests/run.sh stage` only those with "stage" in
their name. They need nothing but jq: each test runs a copy of the tool in a temporary folder, with a fake curl that
answers like Jenkins and GitLab, and fakes for the sounds, dialogs, banners and the keychain.

The settings window has no tests of its own: it keeps no logic, the plugin answers it (`--settings-json`,
`--check-accounts`) and makes every change (`--set`, `--set-team`, `--label-filter`, `--set-token`, `--clear-logs`, …),
and the tests cover those. It only reads the log files itself, to show them. After changing `notifier/*.swift`, rebuild
the app with `notifier/build.sh`.

## License and credits

The code is MIT licensed, see [LICENSE](LICENSE).

The Jenkins icons in `icons/` (`AppIcon.icon` and `app.png` for the app, `happy.png` and `sad.png` for the alert) are
AI-generated images of the Jenkins mascot. The mascot is the [Jenkins logo](https://www.jenkins.io/artwork/) by Charles Lowell and Frontside,
licensed under [CC BY-SA 3.0](https://creativecommons.org/licenses/by-sa/3.0/), and the icons keep that license.
The GitLab logo is a trademark of GitLab Inc.
