- The dry-run filesystem check counted Homebrew's own cache as a script's write.
  A preview of `install_apps.sh` or `brewfile.sh` calls `brew info` to confirm a
  formula name resolves before planning to install it — a read — and Homebrew
  compiles its Ruby into `~/Library/Caches/Homebrew/bootsnap`, some 950 files.
  The scripts store nothing. That path joins the Go telemetry counters on the
  named exclusion list, along with the two bare parent directories Homebrew
  creates on the way to it, matched only where a path ends there so a real write
  to `~/Library/Preferences` still fails. It surfaced only once the snapshot
  started working on macOS: with GNU-only `find -printf` both sides were empty,
  so this had been happening unseen.
