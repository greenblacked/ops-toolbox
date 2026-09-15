- Nine places in `macos-initial-setup/` tested a pipeline ending in a reader
  that stops at the first match — `brew upgrade --help | grep -q -- '--yes'`
  and `tail -n +N "$LOG_FILE" | grep -q index.lock` in `stay_fresh.sh`, four
  `pyenv`/`goenv`/`brew tap`/`helm plugin list` probes in `install_devtools.sh`,
  and the `spctl`/`csrutil` reads in `workstation_doctor.sh`. Under
  `set -o pipefail` the reader's early exit kills the writer with SIGPIPE, the
  pipeline reports 141, and a match reads as a miss. Measured on this repo's
  runner, a writer whose output fits the pipe buffer finishes first and is
  unaffected: 0 of 25 runs lost the match up to about 120 KB, 25 of 25 from
  128 KB. None of these nine is failing today, so this is hardening rather than
  a repair — but which side of that line `stay_fresh.sh` falls on depends on how
  much `brew update` prints, which is a property of the machine's tap count and
  not of the code. All nine now use a here-string, which has no writer to kill.
- The macOS suite gained the check that finds this shape, with the floor every
  check in that folder carries: it fails rather than reports a clean sweep if it
  inspects no file. It is deliberately limited to pipelines in a *tested*
  condition, because SIGPIPE corrupts a pipeline's exit status and not its
  output, so `x="$(cmd | head -n1)"` is safe. The repo-wide check in
  `test-env/static/check_conventions.sh` cannot see any of these: its writer
  pattern is `(printf|echo)`, so `brew upgrade --help | grep -q` never matched
  it, and it reported a clean sweep over a class it was only sampling.
