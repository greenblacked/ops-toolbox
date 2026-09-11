- Every folder README now answers "what do I need" and "what do I run first"
  before it answers anything else. Thirteen of the twenty had no requirements
  section and nine had no quick start, and the two worst were the two largest:
  `mikrotik/README.md` and `git/README.md` ran to hundreds of lines without
  telling a reader how to begin. `mikrotik` and `k8s-toolbox` gained a
  contents list as well, and `windows/wsl`, `test-env/chef` and `test-env/go`
  gained one each. What the requirements say is read out of the scripts rather
  than assumed: which preflight exits `2` for a missing tool, which tool is
  optional and merely warns, and where a version floor is pinned — RouterOS
  7.24.2 in `mikrotik/tests/routeros-version.env`, WinGet 1.6 for
  `winget configure`, the Bash 3.2 that ships on macOS, and Python 3.9 because
  that is what `/usr/bin/python3` is there.
