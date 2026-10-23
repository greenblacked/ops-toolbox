- `windows/git-bash/install_dotfiles.sh --diff` shows exactly what an install
  would overwrite. `--status` said DRIFT and nothing more, so telling your own
  useful edits from an outdated copy meant running `diff` by hand against paths
  inside the checkout. Each drifted file now gets a unified diff labelled
  `installed:` and `repo:`, where a `-` line is something of yours the install
  would remove. It writes nothing and exits like `--status`: 0 when everything
  matches, 4 when anything is missing or different.
