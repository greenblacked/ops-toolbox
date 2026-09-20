- `git/git_ignore_doctor.py` explains why a path is ignored, or why it
  stubbornly is not. `git check-ignore -v` names the rule that matched and
  nothing about why the rule you wrote is not it, so the script asks git twice
  — once with the index, once with `--no-index` — and reads the difference: a
  file committed before its rule existed is not ignored at all, the rule is
  inert until the file leaves the index, and `check-ignore` reports that as no
  match rather than as the trap it is. Run with no argument it sweeps the
  repository for every tracked file an ignore rule claims. It also names a
  negation under an excluded directory, which git can never reach, and prints
  the whole ladder that re-includes the file — `build/*`, `!build/keep/`,
  `!build/keep/note.txt` — because `build/*` on its own leaves the file exactly
  as ignored as it was. Read-only, like the three doctors beside it.
