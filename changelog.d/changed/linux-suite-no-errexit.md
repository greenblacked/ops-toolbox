- `linux/tests/test_linux_scripts.sh` no longer runs under `set -e`. A suite
  that aborts on the first non-zero exit reports the shell's status and
  discards the output it had just captured, which is how a Bash 3.2 parse
  error reached CI as "exit code 2" and nothing else; the 197 `set +e` /
  `set -e` sandwiches the file had grown were the evidence of a running
  fight. Every failure is now a named assertion, the five invocations whose
  result was judged only by the filesystem afterwards are guarded so a run
  that died on line one cannot read as "changed nothing", scratch space is
  proven once at the top, and each `section` fails if it closes having
  asserted nothing — which found one straight away: the "dry run changes
  nothing" heading covered only a helper, its assertions having ended up
  under the Kali heading inserted between them. Same 334 assertions, in 27
  sections.
- Two RouterOS suites had `set +e` / `set -e` sandwiches in files that never
  enabled errexit. `set -e` is not scoped to the function it appears in, so
  the first `run_case` call turned it on for the rest of the file and every
  unguarded command after it became an abort with no message (`$-` read
  `ehuB` after the first call). The sandwiches are gone; the files run as
  their first line says.
- `check_conventions.sh` now fails an assertion suite that enables errexit.
  The two not yet converted (`git/tests`, the macOS native suite) are named
  as exceptions, and a name on that list must still carry a `set -e`, so the
  list cannot outlive the last file it excuses. `CONTRIBUTING.md` no longer
  prescribes the sandwich.
