# MegaMonitor

A native macOS menu bar app for a GitLab project that Jenkins builds with a multibranch job. It shows your builds,
merge requests, work items, checkouts and release slots, and tells you the moment a build finishes.

![The menu bar pane with the Pipelines flyout open: running, failed and passed builds](docs/screenshots/pane.png)

![The main window at Pipelines: the list of builds and the stages of the selected one](docs/screenshots/main-window.png)

More [screenshots](#screenshots) are below. They show made-up data, in dark mode.

## Screenshots

Every screenshot is drawn from the app's design gallery with made-up people, projects and branches; nothing here is a real
team's data. They are in dark mode, and the app follows the system's appearance. `scripts/readme-shots.sh` renders them again.

### Pipelines

![Pipelines with a failed build selected: its stages, the failed tests, the build info, the recent builds with their hints and the console log opened below](docs/screenshots/pipelines.png)

*A failed build shows its stages and failed tests, how it compares to the recent builds (with hints for a likely flaky run), and its console log, with the errors and warnings to jump to.*

![A failed build with Claude's analysis: the verdict, the root cause, the evidence from the log, the suspect commit and the next step](docs/screenshots/why-failed.png)

*With Claude on, "Why Did It Fail?" gives the verdict, the root cause with its evidence, the suspect commits and a next step.*

<img src="docs/screenshots/rebuild-sheet.png" alt="The Rebuild with Changes sheet: the build's parameters as fields, a switch and a menu, with Cancel and Rebuild" width="420">

*Rebuild with Changes: the build's parameters by type, to change before it runs again.*

### Merge requests

![A merge request: the Merge card with the blocked checks, the reviewers, the approvals and the builds](docs/screenshots/merge-request.png)

*What blocks the merge, each with its way to fix it, then the reviewers, the approvals and the builds.*

![The Claude card of a merge request: a question about nine selected lines, Claude's answer with a code block, and the diff with the lines picked and the Ask Claude button](docs/screenshots/ask-claude.png)

*Pick lines in the diff, click Ask Claude, and the question goes with those lines; the answer comes back as Markdown, with code you can copy.*

![The Discussion card: a thread whose comments mention you have an accent bar and an @you badge](docs/screenshots/discussion.png)

*Comments that mention you stand out with an accent bar and an "@you" badge, and their replies start unfolded.*

### Work items, Slots and Workspaces

![A work item: its facts, its merge requests with their builds, its slot with the code freeze countdown and its description](docs/screenshots/work-item.png)

*A work item's facts, the merge requests behind it with their builds, its slot's dates and its description.*

![Slots: the roadmap of the release slots and the current slot with its epics and items](docs/screenshots/slots.png)

*The roadmap of the release slots, and the current one open: its dates, its items by epic, and the ones at risk.*

![Workspaces: six local checkouts with their branch and state, and the selected one's work item, merge request and build](docs/screenshots/workspaces.png)

*Your local checkouts, and the work item, merge request and build behind each one.*

### Inbox and Digest

![The Inbox: My To-Dos, a coffee break, Claude's answer, mentions and review requests](docs/screenshots/inbox.png)

*GitLab's to-dos in groups, with the app's own entries and your own to-dos beside them.*

<img src="docs/screenshots/inbox-panel.png" alt="The Inbox's big panel with the butler sipping a coffee and the line: Warm cups, cold pipelines, that's the plan, and the buttons Done, Snooze 1 Hour and Dismiss" width="380">

*Each kind of event can announce itself with a big panel, a desktop notification or only the Inbox. This one is the weekday coffee break.*

![The Digest: a summary of what needs you today, with the merge requests, reviews, builds and work items behind it](docs/screenshots/digest.png)

*The morning digest, written by Claude when you turn it on: what needs you, in order, with a link to each thing.*

### Settings and alerts

<img src="docs/screenshots/settings-menu-bar.png" alt="Settings, Menu Bar: a live preview of the menu bar item on a light and a dark menu bar, and the list of what it shows" width="420">

*Settings → Menu Bar: a live preview, and what the icon and the pane show, in your order.*

<img src="docs/screenshots/alert.png" alt="The alert of a failed build, with the butler, the build's numbers and the buttons Show Build, Rebuild, Show MR and Dismiss" width="320">

*The alert when a build you follow fails, one of several pages.*

## Install

It needs macOS 26 and the Xcode Command Line Tools (`xcode-select --install`); nothing else, no Xcode and no Homebrew.

1. Put this folder where it will stay: the app remembers it, to update itself from it.
2. In Terminal: `./install.sh`. It builds the app into `~/Applications/MegaMonitor.app` and opens it. (The app was called menubar-monitor before; at its first launch
   it copies your settings, tokens and folders over, and keeps open at login on if it was on. macOS asks for the
   notification permission once more. The old copies stay until `./install.sh --retire-old`.)
3. The welcome flow takes it from there: what it imported from the old tool (see below), your team values (the Jenkins
   job, the GitLab URL and project), the two tokens, the notification permission, and whether to start at login.

`./install.sh --dry-run` prints what would change and changes nothing.

**Getting it onto another Mac:**
- `git clone` the repo and run `./install.sh` there. Don't copy the folder over from another Mac: its `.build` cache
  holds that Mac's paths and the build fails. If you did copy it, `rm -rf .build build`, then run `./install.sh`
  again.
- Don't share a built `MegaMonitor.app`: it is signed only locally. On another Mac it runs as a quarantined copy, and
  macOS won't offer open at login for it.

For the team values, **Settings → Team** can import and export a file without tokens: see `team.example.json`. The
tokens go into the login keychain, **Settings → Accounts** checks that Jenkins and GitLab take them. Jenkins needs your
user and an API token, GitLab a token with the `api` scope (`read_api` is enough to read, but Re-request Review and the Merge card write).

### Update

When the checkout changes (after a `git pull`, say), the app notices and offers **Update Ready — Rebuild** in the
window's toolbar. One click runs `build.sh --install`, opens the new app and quits the old one.
Nothing is rebuilt without that click.

## What it does

- **Menu bar icon and pane**: the icon counts your running, failed, unstable and successful builds, and marks
  problems. Its glass pane is a short overview: one row each for Pipelines, Inbox, Merge Requests and Work Items, with counts
  and a summary. Hover a row (or press →) and a flyout beside the pane lists the items; a click opens one in Jenkins or
  GitLab, and its menu has **Show in Window**. **Check Now**, **Open Window**, Settings and Quit sit at the bottom. **Settings → Menu Bar**
  chooses what the icon shows (the counts, a red dot while the Inbox has something, the butler, a slot countdown) and
  which rows the pane has, in what order and with how long a list, with a live preview.
- **Global hotkey**: **Settings → General** can set a shortcut that opens the main window from any app (and hides it
  again). Off by default.
- **Alerts**: a big alert window or a banner (your choice) when a build you follow finishes, and optionally a banner
  when a stage fails while the build goes on. **Rebuild** starts a finished build again with the same parameters, in
  one click; **Open Console** and **Hide Until the Next Build** are in the alert's menu and on the banner.
- **Main window** (⌘0; ⌘1 and on pick the sidebar's sections, in order):
  - **Pipelines**: your builds and the ones you watch, with stages, failed tests and links. A failed build shows its
    failed test names, and a stage that passed on the same commit is marked **likely flaky**. Its **Console Log** opens
    in the app, with the errors and warnings to jump to, **Find**, and a followed end while the build runs.
  - **Inbox**: GitLab's To-Do List in the app, grouped (mentions, review requests, assigned, builds, other), with Done,
    Restore, Snooze and filters; done and snoozed here is done and snoozed in GitLab. It also holds entries of the app's
    own that never reach GitLab (a Claude answer, the digest, a failed build, a coffee break) and **My To-Dos**, your own
    list on this Mac. **Settings → Notifications** sets per kind whether it shows a big panel, a desktop notification or
    only the Inbox, and whether it counts for the badge.
  - **Merge Requests**: yours, review requested and reviewed, each with a status badge in GitLab's colors and its
    description. The details show the approvals and their rules, the unresolved threads, the code changes, and the GitLab pipeline
    with its jobs. A **Merge** card lists what blocks the merge, with the way to fix each, and merges the way GitLab's
    own Merge button does: Merge, or Set to Auto-Merge while checks are pending, Cancel Auto-Merge, and Mark as Ready for
    a draft, each only on your click; merging asks for a confirmation first, since it can't be undone. **Re-request Review** (↻) asks a reviewer again, or all the ones whose review is older than your last push.
  - **Work Items**: committed and not committed, with filters and label filters, and their related merge requests.
    **New Work Item…** (⌘N) and **New Follow-Up Item** open GitLab's own new issue page, prefilled, in the
    browser.
  - **Activity**: a log of every request, build, alert and problem, with search, filters and a chart of the check times.
    No token is ever kept in it.
  - **Workspaces**: your local checkouts, found in the folders of **Settings → Workspaces**, with their branch, state and
    the merge request or work item behind them. Open one in your IDE (your own command), in Terminal or in Finder.
    The app only reads git; the one write is **Start Work Here** on a clean checkout of its base branch: it fetches,
    then creates the branch named after a work item, after you confirm. A local branch without a merge request offers
    **Create Merge Request**. Terminal opens in the default terminal, or the one you pick in Settings → Workspaces.
  - **Slots**: the release slots of your work items (labels like `2026.51`), with their release, code freeze and early
    access dates computed from the slot's name, a countdown, and the committed items with the state of their merge
    requests and builds, flagged where they are at risk. It is growing into a full slot planning view. An optional
    banner warns before a code freeze.
  - **Digest** (only with Claude on, see below): a summary of what needs you today, a section of its own.
- **Watch a Build…** (⌘L) takes a Jenkins build link (of a merge request or of a branch like `develop`), a GitLab merge
  request link or `!123`, and follows all its builds, the next ones too. A merge request's detail has **Watch Builds**
  for the same. Watched builds alert and hide like yours.
- **Several projects**: **Settings → Projects** adds more Jenkins jobs (same Jenkins and GitLab, same tokens). One check
  covers all of them, the counts are summed, and with more than one project the rows, alerts and the log name theirs.
- **Claude** (on by default with Sonnet when Claude Code is installed; the welcome flow asks, **Settings → Claude** changes it): with **Use Claude** on,
  a failed build gets **Why Did It Fail?** (a verdict, the root cause with its evidence, suspect commits, a next step),
  a merge request or work item gets **Summarize Discussion**, the window gets the **Digest** section, and
  **Continue in Claude Code**, in a chat, starts it in a checkout. It runs your own Claude Code login, sends only what you click (the
  first answer of each kind shows what goes; the morning digest, on by default, runs by itself)
  and removes tokens and keys first. It asks for the models by the CLI's aliases (`opus`, `sonnet`, `haiku`), so any recent
  Claude Code works; `claude update` gets the newest models.
- **Easter eggs**: the butler sometimes has something to say. One switch in **Settings → General** turns them off.
- **Settings** (⌘,): General, Menu Bar, Notifications, Appearance, Accounts, Projects, Team, Pipelines, Work Items,
  Workspaces, Claude and Advanced.
- Jenkins is checked all the time; merge requests and work items load while you look at them, plus a few small
  background requests.

## Coming from jenkins-menubar

The first start imports what the old tool (a SwiftBar plugin with `jenkins-watch`) had: the tokens, the settings, the
team values, and the watched and hidden builds. It imports once, and the old tool keeps working next to it, so you can
compare. Some things can't move, and the welcome flow lists them: the notification permission (macOS keeps it per
app), keychain items made outside `security` (macOS asks once for access), window positions, and the caches.

When you are happy with the new app, remove the old tool:

```
./install.sh --retire-old
```

It unlinks the old SwiftBar plugin, removes SwiftBar from the login items (unless other plugins still need it), removes
the `jenkins-watch` link, unregisters the old helper app and, after a yes, deletes the old caches, logs and keychain
items. It leaves SwiftBar and jq installed and tells you what else is yours to clean up. Add `--dry-run` to see it first.

## Development

The identity is MegaMonitor: bundle id `local.megamonitor`, `megamonitor://` links (the former `menubar-monitor://`
still work), the keychain service `megamonitor`, the folders `~/Library/{Application Support,Caches,Logs}/MegaMonitor`
and the SwiftPM product `megamonitor`; the module names stay `MenubarCore`, `MenubarUI` and `MenubarMonitor`. It was
`menubar-monitor` before; the app copies the former preferences, tokens and folders once at its first launch
(`IdentityMigration`) and leaves the originals for `./install.sh --retire-old`.

```
./build.sh [--debug] [--install]   # builds build/app.noindex/MegaMonitor.app
./test.sh [filter]                 # the Swift Testing tests
scripts/smoke.sh                   # runs the built app once against a local stub server
scripts/gallery-shots.sh all       # screenshots of the design gallery (not committed)
scripts/readme-shots.sh            # refreshes the README's screenshots in docs/screenshots/
```

With Xcode installed, point both scripts at the Command Line Tools to build the way everyone else does:
`DEVELOPER_DIR=/Library/Developer/CommandLineTools ./build.sh`.

Everything builds with only the Command Line Tools, which limits the Swift in use. Swift 6, and no macro that needs
Xcode: views use `@ViewState` instead of `@State` (since the macOS 27 SDK, `@State` is a macro that only compiles with
Xcode), and `build.sh` refuses `@State`, `#Preview`, `@Entry`, `#Predicate`, SwiftData and the like.

- `Sources/MenubarCore`: models, stores, the Jenkins and GitLab clients, scheduling, alerts rules, import. No AppKit or
  SwiftUI.
- `Sources/MenubarUI`: the SwiftUI views (menu bar pane, main window, settings, welcome flow, alert) and the design gallery.
- `Sources/MenubarMonitor`: the app itself: the entry point, the system effects (notifications, keychain, login item)
  and the smoke check.

The debug build has a design gallery (`MegaMonitor --gallery`) that shows every screen with fixtures, in each
appearance, without touching real data. The repository is public, and `scripts/check-names.sh` (run by `build.sh`)
keeps a company name out of its files. How the app handles tokens and what it may do on your behalf is in
[docs/security.md](docs/security.md).

## License and credits

The code is MIT licensed, see [LICENSE](LICENSE).

The Jenkins icons in `icons/` (`AppIcon.icon` and `app.png` for the app, `happy.png` and `sad.png` for the alert, `coffee.png` for the coffee break, `menubar.png` for the menu bar) are
AI-generated images of the Jenkins mascot. The mascot is the [Jenkins logo](https://www.jenkins.io/artwork/) by Charles Lowell and Frontside,
licensed under [CC BY-SA 3.0](https://creativecommons.org/licenses/by-sa/3.0/), and the icons keep that license.
The GitLab logo is a trademark of GitLab Inc.
