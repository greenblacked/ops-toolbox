- `macos-initial-setup/tests/test_macos_initial_setup.sh` no longer runs
  under `set -e`. This is the suite that taught the lesson: an unguarded
  capture of `stay_fresh_agent.sh logs` met a Bash 3.2 parse error in the
  script it was calling, and the macOS job reported "exit 2" and nothing
  else — no failing assertion, no message, and every check below it silently
  unrun. The diagnosis arrived only after that one call site was wrapped in
  `set +e` by hand, and the 84 sandwiches the file had grown were the rest of
  the same fight. Every failure is now a named assertion, so the parse error
  is reported as the assertion that saw it; scratch space is proven once at
  the top instead of at sixteen `mktemp` sites; and each `section` fails if it
  closes having asserted nothing — which found one straight away, the
  "stay_fresh safety contracts" heading that named a block building a fixture,
  its assertions having ended up under the krew heading inserted between them.
  Same 425 assertions, now in 24 sections.
- Thirteen invocations in that suite were judged only by what the filesystem
  looked like afterwards — a preview that must not have deleted a transcript,
  a reconciliation that must not have passed a destructive flag, a report that
  must not have rewritten its own history. A run that died on line one also
  changed nothing, so each of those assertions was one that could not fail.
  They are guarded now, and so is the one loop whose subject list came from a
  command that can fail rather than from a literal.
- With this, no assertion suite runs under `set -e`. `check_conventions.sh`
  drops the list of suites it excused while the three were converted one at a
  time — a list it policed in both directions, so it could not outlive the
  last file on it — and a suite that enables errexit now simply fails.
  `CONTRIBUTING.md` says so, and that a loop fed by a command needs a floor of
  its own.
