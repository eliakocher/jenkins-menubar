# menubar-monitor

A native macOS menu bar app for a GitLab project that Jenkins builds with a multibranch job. It shows your builds,
merge requests and work items, and tells you the moment a build finishes.

![The panel with a running and a failed build, merge requests and work items](docs/panel.png)

![The main window at Pipelines: the list of builds and the stages of the selected one](docs/main-window.png)

## Install

It needs macOS 26 and the Xcode Command Line Tools (`xcode-select --install`); nothing else, no Xcode and no Homebrew.

1. Put this folder where it will stay: the app remembers it, to update itself from it.
2. In Terminal: `./install.sh`. It builds the app into `~/Applications/menubar-monitor.app` and opens it.
3. The welcome flow takes it from there: what it imported from the old tool (see below), your team values (the Jenkins
   job, the GitLab URL and project), the two tokens, the notification permission, and whether to start at login.

`./install.sh --dry-run` prints what would change and changes nothing.

For the team values, **Settings → Team** can import and export a file without tokens: see `team.example.json`. The
tokens go into the login keychain, **Settings → Accounts** checks that Jenkins and GitLab take them. Jenkins needs your
user and an API token, GitLab a token with the `api` scope (`read_api` is enough to read, but re-requesting a review writes).

### Update

When the checkout changes (after a `git pull`, say), the app notices and offers **Update Ready — Rebuild** in the
panel and in the window's toolbar. One click runs `build.sh --install`, opens the new app and quits the old one.
Nothing is rebuilt without that click.

## What it does

- **Menu bar icon and panel**: the icon counts your running, failed, unstable and successful builds, and marks
  problems. The panel lists My Builds with stage, progress and ETA, Watching, Merge Requests and Work Items, with a
  search over all of it.
- **Alerts**: a big alert window or a banner (your choice) when a build you follow finishes, and optionally a banner
  when a stage fails while the build goes on. **Rebuild** starts a finished build again with the same parameters, in
  one click.
- **Main window** (⌘0, sections with ⌘1 to ⌘4):
  - **Pipelines**: your builds and the ones you watch, with stages, failed tests and links.
  - **Merge Requests**: yours, review requested and reviewed, each with a status badge in GitLab's colors and its
    description.
  - **Work Items**: committed and not committed, with filters and label filters, and their related merge requests.
  - **Activity**: a log of every request, build, alert and problem, with search, filters and a chart of the check times.
    No token is ever kept in it.
- **Watch a Build…** (⌘L) takes a Jenkins build link (of a merge request or of a branch like `develop`), a GitLab merge
  request link or `!123`, and follows all its builds, the next ones too. A merge request's detail has **Watch Builds**
  for the same. Watched builds alert and hide like yours.
- **Settings** (⌘,): General, Jenkins, GitLab, Team and Accounts.
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

```
./build.sh [--debug] [--install]   # builds build/menubar-monitor.app
./test.sh [filter]                 # the Swift Testing tests
scripts/smoke.sh                   # runs the built app once against a local stub server
scripts/gallery-shots.sh all       # screenshots of the design gallery (not committed)
```

Everything builds with only the Command Line Tools, which limits the Swift in use. Swift 6, and no macro that needs
Xcode: views use `@ViewState` instead of `@State` (since the macOS 27 SDK, `@State` is a macro that only compiles with
Xcode), and `build.sh` refuses `@State`, `#Preview`, `@Entry`, `#Predicate`, SwiftData and the like.

- `Sources/MenubarCore`: models, stores, the Jenkins and GitLab clients, scheduling, alerts rules, import. No AppKit or
  SwiftUI.
- `Sources/MenubarUI`: the SwiftUI views (panel, main window, settings, welcome flow, alert) and the design gallery.
- `Sources/MenubarMonitor`: the app itself: the entry point, the system effects (notifications, keychain, login item)
  and the smoke check.

The debug build has a design gallery (`menubar-monitor --gallery`) that shows every screen with fixtures, in each
appearance, without touching real data. The repository is public, and `scripts/check-names.sh` (run by `build.sh`)
keeps a company name out of its files.

## License and credits

The code is MIT licensed, see [LICENSE](LICENSE).

The Jenkins icons in `icons/` (`AppIcon.icon` and `app.png` for the app, `happy.png` and `sad.png` for the alert, `menubar.png` for the menu bar) are
AI-generated images of the Jenkins mascot. The mascot is the [Jenkins logo](https://www.jenkins.io/artwork/) by Charles Lowell and Frontside,
licensed under [CC BY-SA 3.0](https://creativecommons.org/licenses/by-sa/3.0/), and the icons keep that license.
The GitLab logo is a trademark of GitLab Inc.
