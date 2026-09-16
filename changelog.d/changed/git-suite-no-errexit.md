- `git/tests/test_git_scripts.sh` no longer runs under `set -e`. A suite that
  aborts on the first non-zero exit reports the shell's status and discards the
  output it had just captured, so the real error never reaches the log; the 31
  `set +e` / `set -e` sandwiches the file had grown were the evidence of a
  running fight. Every failure is now a named assertion, the eight invocations
  whose result was judged only by what the filesystem looks like afterwards are
  guarded so a run that died on line one cannot read as "changed nothing" —
  `git_amend_last.sh` was the worst of them, with all three assertions after it
  holding just as well for the commit it was supposed to change, and the
  restored pre-commit hook the next worst, because the installed hook ends in
  `exit 0` of its own and satisfies the assertion that an uninstall ever ran.
  Scratch space is proven once at the top, where a failed `mktemp` would
  otherwise leave the path empty and point `cd "$repo"` at the checkout itself,
  and each `section` fails if it closes having asserted nothing. Same 269
  assertions, in 26 sections.
- `check_conventions.sh` now excuses one suite rather than two, and counts the
  excused from the list instead of saying "2" in a message that the next
  conversion would have made wrong. `CONTRIBUTING.md` names the macOS native
  suite as the last file still carrying the sandwich.
