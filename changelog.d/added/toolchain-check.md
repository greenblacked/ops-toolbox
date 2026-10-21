- `macos-initial-setup/toolchain_check.sh` reads a checkout's pin files
  (`.python-version`, `.terraform-version`, `.go-version`, `go.mod`,
  `.tool-versions`, `.nvmrc`, `.node-version`) and reports, per tool, whether
  the pinned version is installed in pyenv, tfenv or tenv, goenv, mise or on
  `PATH`, with the install command when it is not, and whether it is the
  binary that actually runs. It installs nothing, never evaluates a pin
  file, and exits 1 on a missing version and 4 when there is no pin, so it
  works as a pre-commit or Makefile guard.
  A prerelease (`rc`, `beta`, `alpha`, `pre`) counts as older than the same
  release, so Go `1.22rc1` does not meet a `1.22` minimum.
