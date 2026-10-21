- The Runbooks section has a runbook for commits that fail to sign or show
  as Unverified. It reads each section of `git_signing_doctor.py`, keeps the
  real signature behind its opt-in `--test-sign`, and points out that the
  usual causes of Unverified are warnings that leave the exit code at `0`.
  It points at `git_ssh_doctor.py` for transport authentication, which is a
  separate mechanism.
