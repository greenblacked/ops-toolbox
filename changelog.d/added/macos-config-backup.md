- `macos-initial-setup/config_backup.sh` keeps a dated, verified and rotated
  archive of a Mac's non-secret dotfiles and tool configuration (`.zshrc`,
  `.gitconfig`, `.ssh/config`, `.aws/config`, LaunchAgents and the like) in
  `~/ops-toolbox-backups`, the macOS counterpart of
  `linux/config_backup.sh`. Paths that hold credentials (any non-config,
  non-public-key file under `~/.ssh`, the git credential store,
  `~/.terraform.d/credentials.tfrc.json`, `~/.pypirc`, gcloud's
  application-default credentials, `credentials.db` and
  `legacy_credentials/`, a `~/.terraformrc` with a `credentials` block, a
  `~/.aws/config` with `aws_access_key_id`, `aws_secret_access_key` or
  `aws_session_token`) are refused unless `--include-secrets` and left out
  of a default run, the archive is private to its owner (a `--dest` it
  creates is `0700`, and one other users can write to is refused, as is one
  below an ancestor directory that is not owned by root or you, or that
  other users can write to unless it is sticky; the temporary archive is
  made exclusively with `mktemp`), a dry run writes nothing, a real run
  needs `--yes`, and rotation only removes its own older archives. A
  `--dest` that reaches a source through a symlink is refused too, and a
  `--paths` entry is judged by where it really points as well as by its
  name, so an alias folder onto `~/.aws` does not hide credentials.
  A `--dest` whose extended ACL (`ls -le`) has an allow entry that lets
  anyone but its owner, root or wheel list it or change its contents is
  refused before anything is written (fix: `chmod -N DIR`).
