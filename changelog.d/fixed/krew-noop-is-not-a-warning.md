- `stay_fresh.sh` warned once per kubectl plugin on a machine that was fully up
  to date. `kubectl krew upgrade` exits non-zero when a plugin is already at the
  newest version, which is the answer "nothing to do" — and on a current machine
  it is the answer for every plugin, so the step closed with a WARN verdict for
  doing exactly what it should. This package documented that exit code as
  expected rather than acting on it, which left the warnings in the log; a
  warning nobody should act on is what teaches people to skip the ones they
  should. The message now decides, a real failure still warns, and the step says
  how many plugins were already current.
- The same step puts `$KREW_ROOT/bin` on `PATH` for its own calls. krew prints a
  four-line `WARNING` on every invocation when that directory is missing from
  `PATH`, and a scheduled run has the environment launchd hands it rather than
  the one `~/.zshrc` builds, so a clean run carried three copies of it.
