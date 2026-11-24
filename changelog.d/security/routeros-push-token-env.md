- The RouterOS bump workflow no longer passes its push token on the `git`
  command line (`git -c http.https://github.com/.extraheader=...`), where any
  process on the runner could read it. The token now reaches only the
  `ls-remote`, `fetch` and `push` calls through `GIT_CONFIG_*` environment
  variables, stays masked, and is still never written to `.git/config`.
