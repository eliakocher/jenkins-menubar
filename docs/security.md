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
  Set to Auto-Merge, Cancel Auto-Merge, Rebase and Mark as Ready. Each needs a click; no link, launch, timer,
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

## Accepted risks

- **Software running as you can read the tokens.** Items written through `/usr/bin/security` trust that tool, so any
  process of yours can read them without a prompt. It's the price of ad-hoc builds (items the app wrote itself would
  ask for access after every rebuild), and the same exposure as tokens exported in a shell profile.
- **Captured requests keep response bodies** (MR text, build logs) in `~/Library/Logs/MegaMonitor`, readable only by
  you, capped in size.
- **Rebuild builds what is in your checkout.** What you `git pull` is what you run.
- **Continue in Claude Code** starts Claude Code with your own permissions and settings, on a prompt that includes the
  item's text.
- **The opt-in Claude setup** uses your own MCP servers and allow rules, and tool output is not redacted.
  One gap is left: a connector you add on claude.ai that no Claude Code run on this Mac has seen yet isn't in any
  local file, so it is denied only after the next listing (a quiet refresh in the background at most 15 minutes after
  a chat, or Refresh in Settings). It matters only if your own allow rules would let that server's tools run.
- **Ad-hoc signing**, no hardened runtime: fine while everyone builds from source; never share a built bundle.

## Uninstalling

Not automated yet. Turn "Open GitLab and Jenkins Links in MegaMonitor" off first (or pick another default browser),
quit the app and delete `~/Applications/MegaMonitor.app`. Then delete `~/Library/Application Support/MegaMonitor`,
`~/Library/Caches/MegaMonitor` and `~/Library/Logs/MegaMonitor`, the defaults with
`defaults delete local.megamonitor`, and the two Keychain items of the service `megamonitor`
(`security delete-generic-password -s megamonitor -a <account>`, or Keychain Access).
