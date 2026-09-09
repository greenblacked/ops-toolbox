- `git/clone-repos.sh` clones every repository listed in a text file into
  one parent directory, one URL per line with an optional destination, and
  `repos.txt.example` shows the format. A checkout that is already there is
  skipped, an occupied path is reported and left alone, and one bad line
  never stops the rest; the exit code says whether everything landed. It
  follows the package's contract: `--help` before any check, `3` on a bad
  flag, both `--dir DIR` and `--dir=DIR`, and a `--dry-run` that prints the
  clones it would run and writes nothing. `gclone` is its alias in both
  alias files.
