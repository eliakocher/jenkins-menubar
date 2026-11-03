# Changelog

All notable changes to MegaMonitor. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
versions follow [Semantic Versioning](https://semver.org/). The version lives in `build.sh` (`CFBundleShortVersionString`).

## [Unreleased]

## [1.0.6] - 2026-11-03

### Added
- **Your slash commands and skills work in the Claude card, as in Claude Code** (with "Use My Claude Code Setup" on).
  Claude can run git and your MCP tools, asking you first with **Allow**, **Always for This Chat** or **Deny**, and
  it can ask you questions with buttons.
- Claude's answers **stream into the card**, each tool call shows as a quiet line, and **Stop** interrupts.
- **Raw Response** under an answer shows its Markdown source and the run's details, with Copy.
- **Mega Corners** in Settings: each screen corner runs an action like macOS's own hot corners, a shortcut or an app,
  and another one with ⌘, ⌥, ⌃ or ⇧ held.
- Mega Corners can open a MegaMonitor section, Search, Refresh Now, or mute alerts for an hour.
- **Corner glow:** a Mega Corner can light up its corner when it fires. Pick the color, Glow, Pulse or Ripple, the
  duration, the opacity and the size, and try it on the screen from Settings.
- The settings of the old Hot Corners app are imported once, with a warning and a Quit button while it still runs.
- **What's New stands out:** after an update it shows as a colourful animated card on top of the Inbox, and the Inbox
  in the sidebar and in the menu bar pane wears a small gift until you open it.

### Changed
- **Add Required Reviewers shows who it adds:** those people come first in the Suggested row, marked "Required".
  Hovering the button highlights them, and its tooltip lists them by approval rule.

### Fixed
- The suggested reviewers no longer use the sparkles symbol, which means Claude.
- In a question about code, a skill can no longer read files outside the checkout.
- A window opened by a Mega Corner now comes in front of other apps.
- **The peeking butler only shows up in a MegaMonitor window while you're looking at it** (the window is focused). If
  you switch away while he's out, he ducks back right away. The menu bar pane works as before.

## [1.0.5] - 2026-11-03

### Added
- **What's New:** after an update, the Inbox gets a "What's new in x.y.z" entry in its own What's New group. It opens
  every version's changes since the one you last ran, and **Help → What's New…** shows them all anytime. Its delivery
  is Inbox Only by default (Settings → Notifications).

### Fixed
- **The butler peeks out about half a second after you open the menu bar pane**, instead of making you wait 5 to 10
  seconds (Surprise Me and the random peeks).

### Changed
- **Rebuilding shows a percentage:** "Rebuilding 42%" with a progress ring in the window's toolbar, and the percentage
  in the menu bar pane.
- **The Merge card** of a merge request shows its last known state at once, with a small spinner while it reloads,
  instead of a skeleton. Merging stays off ("Checking…") until GitLab has confirmed the state.

## [1.0.4] - 2026-11-03

### Fixed
- Opening the menu bar pane while the butler is about to peek no longer crashes the app.

## [1.0.3] - 2026-11-03

### Added
- Pipelines:
  - **Watch** for a job you don't follow yet, from its build detail.
  - **Save…** in the console log, which writes the whole log to a file, with progress and Cancel.
  - **Jump to a stage:** a click on a stage in the Stages card opens the console log at that stage's first line.
- Merge Requests:
  - **Suggested reviewers** as chips in the Reviewers card of your own MRs (code owners and the approval rules), each
    with Add, plus Add Required Reviewers. They're sent only on your click.
  - The MR detail skips the related-issues request when the title already names the work item: one request and about
    80 KB less for most MRs.
- Slots: **arrow keys** move through the item rows, Return opens the item, ← closes the slot.
- **Search over an Opened item** searches its own section (builds, merge requests or work items) and starts empty.
- **The fun layer**, behind the Easter eggs setting, with a new **Fun level** (Subtle, Normal or Party; Party by
  default) and a **Surprise Me** button in Settings → General:
  - moments that react to your builds: a redemption, green streaks, a third failure, a Friday failure, a long build,
    Monday's first, the 1000th build;
  - a daily Butler's Tip in the pane and in the empty states, and lines at lunch, going home and late at night;
  - a **peeking butler**: he shows up from window edges now and then, and you can catch him (there's a counter in
    About). In the menu bar pane he leans out from behind its edge, on the side that's free of the flyout;
  - confetti, a bounce or shake for the alert's butler, coffee steam, fireworks at New Year;
  - **sad weather** for red builds: rain for a failure, a drizzle for unstable, and a thunderstorm for the third failure
    in a row or a Friday failure (Party);
  - **seasonal butlers**:
    - Halloween, Oct 17 – Nov 7;
    - Carnival, on set dates for 2027–2030;
    - Easter, Palm Sunday to Easter Monday, computed each year;
    - New Year, Dec 31 – Jan 14;
    - Santa, all of December;
  - a small hop of the menu bar icon now and then;
  - fresh lines written by Claude Haiku in one small batch a day, with none of your data. The built-in lines are the
    fallback.

### Changed
- The alerts tell your own builds from watched ones ("Your build" / "Watching · by …"), and watched builds offer no
  Rebuild.

### Fixed
- **Open at login** is never greyed out. When macOS can't register the app, it says why (a quarantined copy, outside
  an Applications folder), and **Open Login Items Settings…** lets you add it by hand.
- **README:** installing on another Mac: clone and run `./install.sh`, and don't copy `.build` or a built app.
- **Stop Watching** works for jobs of a second project too.
- **The console log** no longer hides the first characters under the line numbers after a jump.
- **`install.sh`** quits only the installed app, then checks that it started.
- Spotlight no longer lists the build copies: builds go to `build/app.noindex/`.

## [1.0.2] - 2026-11-03

### Added
- **Settings → Shortcuts:** every command with its key and a recorder, conflicts flagged, keys macOS reserves refused,
  Reset per row and for all. Toggle Sidebar can be set to ⌘S.
- **Settings → Appearance:** Automatic, Light or Dark for the whole app. The menu bar icon follows the menu bar.
- **The Claude card in every build detail,** with a free question box, Summarize Build and What Changed?. Why Did It
  Fail? stays on red builds.
- **A Claude step in the welcome flow:** Claude features, the model, the daily digest and the coffee break.
- **The coffee butler art** in the coffee panel, its notification and its Inbox row.
- **About window:** two-column movie credits that roll slowly, with the version read from the app.

### Changed
- **Claude is on by default** for new installs, with Sonnet, the daily digest at 9:00 and the coffee break at 8:59.
- **Claude models** are passed as aliases (`opus`, `sonnet`, `haiku`), so any recent Claude Code works and
  `claude update` brings newer models. A too-old Claude Code gets a clear "claude update" note. Settings → Claude
  shows the installed version.
- **One setting for finished builds** (Big Panel / Desktop Notification / Inbox Only) under Settings → Notifications,
  instead of two.
- **Lists keep their selection** when you click empty space or a header. When the selected row goes away, its
  neighbour takes over.
- **Work item header:** at most 2 fact columns.
- **Slots:** type chips read "Feature" and are grey, except Bug.
- **The Digest's unread dot** is red.
- **My To-Dos** show without a GitLab token.
- **The MR header** has no Ask Claude button; the Claude card is further down.

### Fixed
- A failed build no longer shows both the big panel and a desktop notification.
- A refused Done in the event panel shows the reason.
- The MR list no longer shows a lone "!" before an MR number is known.

## [1.0.1] - 2026-11-03

### Added
- **Inbox:** your GitLab to-dos, grouped. It has Done, Snooze, Mark All Done, a badge in the sidebar, a red dot on the
  menu bar icon and a row in the menu bar pane.
  - **Local entries:** Claude answers, the digest, failed builds and the coffee break.
  - **My To-Dos:** your own to-dos.
  - **Delivery per event type:** Big Panel, Desktop Notification or Inbox Only.
  - **Group order:** set in Settings.
  - **@you:** comments that mention you stand out.
- **Coffee break:** every weekday at 8:59, with a line by Claude Haiku. It can't be snoozed.
- **Merge card** in the MR detail. It shows the checks with a fix for each, the options, and Merge or Set to
  Auto-Merge. It calls GitLab's own merge API and asks once before merging.
- **Recently Merged** section in the Merge Requests list.
- **Console log** in the build detail. It loads lazily, has colours, line numbers, error jumps and search, and follows
  a running build live.
- **Settings → Menu Bar:**
  - what the icon shows: counts, the Inbox dot or count, reviews, the freeze countdown;
  - the pane's rows and their order;
  - a live preview.
- **Rebuild with Changes…**, which edits a build's parameters before rebuilding.
- **Copy Branch Name** for work items.
- **Sidebar order:** drag the sidebar sections into your own order.
- **Light / dark README screenshots** with demo data (`scripts/readme-shots.sh`).
- **Claude answer jump:** clicking a Claude answer in the Inbox scrolls to and highlights the Claude card.

### Changed
- **One look for references:** work items are a blue "#" chip and merge requests a green "!" chip, everywhere.
- **Alerts page through** one panel instead of stacking.
- **Work item header:** a facts panel, and only the item's own MRs (the rest are under "Mentioned in").
- **Slots table:** leaner, with the type and MR chips under the title.
- **Opened sidebar rows:** two lines, with coloured symbols.

### Fixed
- A GitLab answer with errors no longer shows as "token rejected". GitLab's reason is shown, and a read-only token is
  named.
- Recent Builds tiles stay clickable in an opened build.

## [1.0] - 2026-11-02

The first full version: the menu bar pane, the main window with Pipelines, Merge Requests, Work Items, Activity,
Workspaces, Slots and the Digest, alerts, Claude features, and the welcome flow.
