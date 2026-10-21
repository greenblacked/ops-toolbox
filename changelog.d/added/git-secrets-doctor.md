- `git/git_secrets_doctor.py` audits what a repository has already
  committed: tracked files with credential-shaped names (`.env`, private
  keys, Terraform state, `.git-credentials`, kubeconfig and more, with
  `.env.example`-style placeholders exempt), tracked content matching a
  private key block or a known token format, and with `--history` files that
  were deleted from the tree but are still in history, where the credential
  has to be rotated. Content is searched with `git grep -l`, so a matched
  secret is never printed; `--allow` leaves out documented fixtures and
  `--no-content` skips the content search on very large trees.
