- `check_conventions.sh` reported that `set_git_profile.sh` accepts
  `--profile VALUE` but not `--profile=VALUE`, on a script that accepts both.
  The check asked with `printf … | grep -qx`: `grep -q` exits at the first
  match, which kills `printf` with SIGPIPE, and under `set -o pipefail` the
  pipeline reports 141 — so finding the flag was indistinguishable from not
  finding it. Whether the writer had finished before the reader left decided
  the answer, which is why it failed on macOS and passed on Linux. The same
  file carried four of these, and four more sat in `system_doctor.sh` and
  `linux/install_devtools.sh`, where the symptom was a stray
  `write error: Broken pipe` in otherwise clean output. All eight now read from
  a here-string, which has no writer to kill.
- A new check reads every tracked shell file that sets `pipefail` and fails on
  a pipeline into a reader that exits early. It reads rather than runs, so
  unlike the rest of the suite it also scans the test infrastructure — the file
  that had four of them would otherwise have gone on exempting itself.
