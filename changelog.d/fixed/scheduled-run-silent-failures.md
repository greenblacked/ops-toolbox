- A scheduled `stay_fresh.sh` run that could not start said so to nobody. The
  end-of-run notification lives past the step loop, so every guard that exits 2
  before it — not macOS, running as root, no terminal without `--yes`, `HOME`
  unset, and another run holding the lock — was silent on the macOS banner,
  Telegram and Slack alike. A schedule that has stopped doing anything then
  looks exactly like a schedule with nothing to do, which is the failure the
  notification path exists to prevent. Those paths now send one
  `stay_fresh FAILED: <reason>` notification first. It is deliberately not
  gated by `--notify-when`, because `warn` and `fail` describe the verdict of a
  run that ran and a run that could not start has no verdict; `--notify none`
  still silences it. Only the macOS banner is used when `HOME` is unusable,
  since the Telegram and Slack credentials are read from under it.
- The LaunchAgent sent both of its standard streams to `/dev/null`, so a firing
  that died before it could open its own log — the checkout moved and the
  script is no longer where the plist points, a log directory that cannot be
  created — stopped the schedule with no output anywhere. stderr now lands in
  `~/Library/Logs/stay_fresh/agent-launchd.err`. stdout stays discarded: a
  healthy run's chatter is already in its own timestamped transcript.
- `tmutil status` ran as a bare command substitution in the snapshot step, the
  one probe there that `--step-timeout` could not reach. It talks to backupd,
  and on a Mac whose Time Machine destination is an unreachable network share
  it blocks and takes the run with it. It now goes through `capture_cmd`, and
  the failure path changed with it: the old code left the status empty on
  error, so the "is a backup running" test did not match and the run thinned.
  Once a hang becomes a timeout that would mean thinning under a backup it
  could not see — the exact outcome the guard exists to prevent, and worse than
  the hang. A probe that cannot answer now keeps the snapshots.
- The macOS suite's own `bash -n` check ran under the wrong interpreter.
  `Test / macos native` starts the suite with `/bin/bash` — the Bash 3.2 every
  Mac ships, and the only interpreter in CI that parses the way a user's
  machine will — but the check shelled out to a bare `bash`, which resolves
  through `PATH`, and that runner has Homebrew's Bash 5 ahead of `/bin`. So the
  one check whose job is to catch a Bash 3.2 parse error was asking Bash 5, and
  passed a file 3.2 refuses. It now uses `"$BASH"`, the interpreter actually
  running the suite. This was found the hard way: an apostrophe added to the
  LaunchAgent plist heredoc parsed cleanly under Bash 5 everywhere, and 3.2 —
  which does not treat a heredoc body inside `$( )` as opaque — read it as an
  unterminated quote and followed it to end of file. The suite then died at the
  first script it ran, reporting the shell's exit code and nothing else.
