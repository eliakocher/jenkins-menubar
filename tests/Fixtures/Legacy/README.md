# A made-up copy of jenkins-menubar's files

The import tests (`Tests/MenubarCoreTests/Import/`) copy these into a temporary folder. The layout is the old
tool's, the values are made up: no real host, name, job or token.

- `checkout/`: the old tool's folder, with `config/settings` (every key the old plugin wrote, set away from the
  defaults), `config/team.conf`, and stand-ins for `plugins/jenkins.30s.sh` and `bin/jenkins-watch`, which the
  SwiftBar and `~/bin` links lead to.
- `caches/`: `~/Library/Caches/jenkins-menubar`, with `watched` (one job per line) and `hidden` (`job<TAB>number`).
- `zshrc`: a `~/.zshrc` with a single-quoted and a double-quoted export with a comment after it.
