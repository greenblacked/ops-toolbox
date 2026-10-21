- `git/git_submodule_doctor.py` explains submodule failures before they
  reach CI: a gitlink with no `.gitmodules` entry ("no submodule mapping
  found"), a stale entry, a submodule not initialised or checked out at a
  different commit than the superproject records, a merge conflict in the
  pointer, a URL that is a path on one machine or uses `git://` or
  `http://`, an ssh URL that needs a deploy key on every runner, and a
  `.git/config` still dialling an old URL until `git submodule sync`. It
  prints each repair, runs none, and blanks passwords in the URLs it shows.
  It takes `--quiet` and `--json` like the other doctors.
