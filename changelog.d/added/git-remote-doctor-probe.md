- `git_remote_doctor.py --probe` checks that each remote can actually be
  fetched from with the credentials this machine has, by running one
  non-interactive `git ls-remote --heads` per remote and `--url`. A failure is
  named as one cause (DNS, network, timeout, ssh key, unknown or changed host
  key, HTTP token, repository not found, TLS or proxy) with the next command
  to run, so "Could not read from remote repository" stops being the whole
  diagnosis. Nothing can prompt, git's error lines are redacted before they
  are printed, each probe is bounded by `--probe-timeout`, and the default
  run stays offline.
