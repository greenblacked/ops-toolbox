- `git/git_hooks_install.sh` gains an opt-in pre-push hook with
  `--pre-push`: it refuses any push to `main` or `master` (or the branches
  named with `--protect`), naming a deletion or a force push as such, and any
  push carrying `fixup!`, `squash!`, `amend!` or `WIP` commits that were meant
  to be squashed first. A default install is unchanged, a foreign pre-push
  hook is backed up only with `--force` and restored on uninstall, and one
  push can be let through with `git push --no-verify`.
