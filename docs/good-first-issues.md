# Good first issues

Small, self-contained tasks, each one a real gap that exists in the tree today
rather than invented busywork. Every entry names the file to change and the
command that tells you whether the change worked.

Read [`CONTRIBUTING.md`](../CONTRIBUTING.md) first — it is short, and it is
where the conventions these tasks ask you to follow are written down with the
file and line that establishes each one.

Before you start, get a green baseline so you can tell your change apart from
something that was already broken:

```bash
./run-tests.sh python static k8s      # no Docker needed
npx markdownlint-cli2 --config .markdownlint-cli2.yaml '**/*.md'
```

## Contents

- [Resolved](#resolved)

There is no open entry at the moment. The five that used to live here were
real gaps and are now done; they moved to Resolved rather than sitting in
the list being wrong. File a
[script request](../.github/ISSUE_TEMPLATE/script_request.md) if you have a
chore this repository does not cover yet.

## Resolved

Removed from the list above once the tree stopped matching the description.
Kept as a short record, because the point of this file is that every entry is a
real gap and a stale one undermines the rest.

- **Document `macos_defaults.sh` in the macOS README.** It has a table of
  contents entry, a folder-map row, and a section of its own.
- **The three missing script sections in `git/README.md`.** `git_prune_gone.sh`,
  `git_size_report.sh` and `git_signing_doctor.py` each have a section taken
  from `--help`.
- **A table of contents for `git/README.md`.** Every `##` heading has an
  entry, matching `macos-initial-setup/README.md` and the root README.
- **An issue-template `config.yml`.** `.github/ISSUE_TEMPLATE/config.yml` sets
  `blank_issues_enabled` and points `contact_links` at the private security
  advisory form in `SECURITY.md`.
- **Behavioural tests for `git_prune_gone.sh` and `git_size_report.sh`.** The
  git suite covers dry-run (including that it does not fetch), include/exclude
  filters, restore-oriented output, `--ref` scoping, a missing ref exiting
  `4`, and `--fast` skipping the history walk.
- **`NO_COLOR` in the seven scripts that ignored it.** All of them test the
  variable as well as the terminal now:
  `grep -rl 'C_RESET=' --include='*.sh' . | xargs grep -L 'NO_COLOR'` prints
  nothing.
- **The stale `NO_COLOR` sentence in `CONTRIBUTING.md`.** The Output section
  says every Bash script honours it, which is what the tree does.
- **The two out-of-date test descriptions in `README.md`.** The Testing section
  lists the current fast selection, and the Continuous integration section says
  every suite except the RouterOS one.
- **`templates/new_script.ps1` outside the PowerShell contract suite.**
  `windows/tests/contract.ps1` discovers `templates/*.ps1` alongside
  `windows/`, so the template's help and its dry run are checked like
  everything else.
