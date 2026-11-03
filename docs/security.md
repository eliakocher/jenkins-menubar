# Security

How MegaMonitor handles secrets and what it may do on your behalf. Written during the audit before the first release
to a team (2026-11-02).

## The threat model

MegaMonitor is an internal tool for a team that trusts each other. It runs as you, on your Mac, with your tokens, and
talks only to your team's own GitLab and Jenkins. It is built from source on each Mac (`install.sh`); no prebuilt bundle
is shared.

So it guards against **accidents and leaks**, not against colleagues attacking each other:

- **The public repository** must never hold a token, a real host or anything private.
- **Your tokens** must stay in the Keychain and go only to the servers you configured.
- **Nothing writes** to GitLab or Jenkins, and no command runs, unless you clicked for it.

Out of scope: a colleague deliberately crafting MR text, team files or links to attack another colleague, malware
already running as you, and a compromised GitLab or Jenkins.

## What is protected, and how

### The repository

- No tokens, real hosts or real names in code, tests, fixtures or docs: the fixtures use `example.com` and made-up
  names, and `scripts/check-names.sh` (run by `build.sh` and `test.sh`) refuses the company's name.
- Planning and Claude files are git-ignored.
- Dependencies (swift-markdown, swift-cmark) are pinned to an exact version and revision; `Package.resolved` is
  committed. There are no build plugins, macros or binaries in the repository.

### Tokens

- Stored only in the login Keychain, through `/usr/bin/security -i` with the value on stdin, never on a command line.
- Sent only in the `Authorization` header, never in a URL, over HTTPS, to the configured GitLab and Jenkins hosts. The
  URL session is ephemeral (no cookies, cache or credential store).
- Never in logs, captured requests (only the auth scheme is kept; "Copy as cURL" uses `$GITLAB_TOKEN`), team files,
  settings backups, process arguments or environments, the gallery or test fixtures.
- Everything the app itself sends to Claude goes through `SecretRedactor`, which removes the stored tokens, auth
  headers, URL passwords, private keys and the common token formats.
- The GitLab token needs `read_api` for everything except Re-request Review and the Merge card's writes, which need
  `api`.

### Writes and commands

- The server writes: Rebuild and Cancel Rebuild on Jenkins; on GitLab, Re-request Review and the Merge card's Merge,
  Set to Auto-Merge, Cancel Auto-Merge and Mark as Ready (no rebase). Each needs a click; no link, launch, timer,
  notification arriving or Claude answer triggers one.
- Merge asks for a confirmation in the app first, since it can't be undone. Merge and auto-merge send the head commit
  the card showed (`sha`), so GitLab refuses a merge that would take commits pushed since; the request carries the token
  in the header only, and the logs keep the operation's name and the options, never the token.
- The one local git write, Start Work, needs a confirmation and a clean checkout, and never forces anything. Background
  git only reads.
- Every program is started with an argument list, never a shell string. Continue in Claude Code uses a fixed script that
  reads its values from private temporary files.
- `megamonitor://` links only navigate, watch a job on the configured Jenkins, or offer a team file import that applies
  nothing before you click Apply.

### Claude

- Runs through your own `claude` login; the app holds no API key.
- By default each call runs isolated (safe mode): no plugins, hooks, MCP servers or CLAUDE.md, no tools except reading
  inside the checkout for code questions, a budget limit and a timeout.
- "Use My Claude Code Setup" is opt-in and only for chats. It allows only the MCP tools that read, from the servers
  you turned on, and denies every tool that changes or runs something, including servers that weren't connected when
  the tools were listed. Before each chat the app also reads the server names in your Claude Code config and denies
  every one the tool listing didn't know, so a server you add later stays off until the listing is made again.
- With the setup on, a chat that doesn't read a checkout also gets the Skill tool, so Claude can load your skills as in
  Claude Code. A skill's `allowed-tools` grants its tools past `--permission-mode dontAsk`; only a tool that is missing
  from `--tools` or denied by name stays off. Probed with Claude Code 2.1.317 and a skill whose `allowed-tools` asked
  for `Bash(touch:*)` and `Write` and whose text said to create a file: with the chat's flags the file was never
  created, through the Skill tool or a typed `/command`, and its `` !`command` `` lines were refused too. Without those
  denials the same skill created the file. The changing MCP tools are denied by name or by server prefix in the same
  list, so they hold the same way (inferred from the flags, not probed against a real server).
- With the setup on, the chats (a merge request's, a work item's and a build's Claude card, and every follow-up) run
  Claude Code as in a terminal, hosted by the card: `--input-format stream-json --permission-prompt-tool stdio
  --permission-mode default`, in the item's checkout when there is one, else in an empty folder of the app's. Every
  tool call that the user's own allow rules (or a skill's `allowed-tools`) don't already allow shows in the card with
  Allow, Always for This Chat and Deny, and nothing runs until the developer clicks; the app never answers a request
  by itself. "Always for This Chat" sends only Claude Code's `addRules` suggestions that allow, with their destination
  forced to `session`: never `setMode` (it would let later, different calls run unasked) and never a destination that
  writes a settings file (sent back unchanged, a suggestion wrote the checkout's `.claude/settings.local.json` in the
  probe; with `session` none was written, and the same command ran again unasked, probed with 2.1.317). The default
  mode is set explicitly, since a user's own `defaultMode` of `auto` let calls run unasked. WebFetch, WebSearch and the
  MCP servers that are off stay denied. The facts go in as the first message on stdin, redacted; the log keeps the use
  case, the outcome and the names of the tools allowed or denied, never text or a tool's input. One process per card,
  ended by Clear, a new first question, a minute after the card leaves the screen, or ten idle minutes; its budget
  guard stays. The headless read-only run of the chats stays as the fallback
  (`defaults write local.megamonitor ai.hostChats -bool NO`).
- A question about code with a checkout keeps Read, Grep and Glob inside the checkout with a `PreToolUse` hook, so it
  gets the Skill tool too. A skill's `allowed-tools: Read` lets Read open any path past `dontAsk`, but a hook's denial
  beats that grant. The hook is the app's own program (`megamonitor --claude-read-guard`, passed with `--settings`);
  the checkout reaches it through the environment, never through a shell line. It resolves symlinks, refuses `..`,
  `~` and patterns that climb or start elsewhere, treats a missing path as the checkout, and a hook that can't run
  blocks the call (`|| exit 2`). Its settings set `disableAllHooks: false`, which outranks the user's own. Probed with
  Claude Code 2.1.317 and a skill allowing `Read, Grep, Glob`: an absolute path, `..`, a symlinked file and folder, a
  Glob of `../**`, an absolute Glob pattern and a Grep with a path outside were all refused, a project setting
  `disableAllHooks: true` and a project hook answering "allow" changed nothing, and a missing hook program refused the
  read. Grep and Glob over the checkout don't follow symlinks out (probed).

## Accepted risks

- **Software running as you can read the tokens.** Items written through `/usr/bin/security` trust that tool, so any
  process of yours can read them without a prompt. It's the price of ad-hoc builds (items the app wrote itself would
  ask for access after every rebuild), and the same exposure as tokens exported in a shell profile.
- **Captured requests keep response bodies** (MR text, build logs) in `~/Library/Logs/MegaMonitor`, readable only by
  you, capped in size.
- **Rebuild builds what is in your checkout.** What you `git pull` is what you run.
- **Continue in Claude Code** starts Claude Code with your own permissions and settings, on a prompt that includes the
  item's text.
- **A hosted chat is Claude Code with you at the wheel.** What you allow in the card runs as you, in the checkout, like
  in a terminal; your own allow rules and your skills' `allowed-tools` run without asking, as they do in Claude Code.
  A Read outside the working folder asks, unless one of those allows it (inferred from the default mode, not probed).
- **The opt-in Claude setup** uses your own MCP servers and allow rules, and tool output is not redacted.
  One gap is left: a connector you add on claude.ai that no Claude Code run on this Mac has seen yet isn't in any
  local file, so it is denied only after the next listing (a quiet refresh in the background at most 15 minutes after
  a chat, or Refresh in Settings). It matters only if your own allow rules would let that server's tools run.
  The same holds for a tool a server adds after the listing: neither allowed nor denied by name, so your own allow
  rules or a skill's `allowed-tools` could let it run until the next listing.
- **Ad-hoc signing**, no hardened runtime: fine while everyone builds from source; never share a built bundle.

## Uninstalling

Not automated yet. Turn "Open GitLab and Jenkins Links in MegaMonitor" off first (or pick another default browser),
quit the app and delete `~/Applications/MegaMonitor.app`. Then delete `~/Library/Application Support/MegaMonitor`,
`~/Library/Caches/MegaMonitor` and `~/Library/Logs/MegaMonitor`, the defaults with
`defaults delete local.megamonitor`, and the two Keychain items of the service `megamonitor`
(`security delete-generic-password -s megamonitor -a <account>`, or Keychain Access).
