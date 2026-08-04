# Changelog

All notable changes to this repository are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
releases will follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once there is a tag to hang a version on.

There is no tag yet, so nothing below carries a release number. The dated
sections are reconstructed from the merge commits in `git log` and are grouped
by the day each pull request landed on `master`; they are history, not releases.
The first tagged version will be cut from `[Unreleased]`, and from then on every
entry here belongs to a version.

## [Unreleased]

### Changed

- RouterOS CHR compatibility was bumped from 7.22 to 7.23.3 after the full Docker integration suite passed.
- **The repository was renamed from `pretty-useful-scripts` to `ops-toolbox`.**
  GitHub redirects the old URLs, so existing clones and links keep working;
  run `git remote set-url origin` to stop git warning on every fetch. Creating
  a new repository under the old name would break those redirects permanently.
- `set_git_profile.sh` now stores profiles under
  `${XDG_CONFIG_HOME:-$HOME/.config}/ops-toolbox/git-profiles.conf`. Profiles
  saved under the old directory are still read when the new path does not
  exist, and `--show` prints the command to migrate them. Nothing has to be
  moved by hand, and nothing is moved automatically.
- `git_hooks_install.sh` backs foreign hooks up to `.hooks-install-backup`
  rather than `.pre-pus-backup`, which abbreviated the old repository name.
- The Go test module is now `github.com/greenblacked/ops-toolbox/test-env/go`,
  which also adds the owner segment the old path was missing.

### Added

- `mikrotik/tests/routeros_version.py` and a twice-weekly/manual GitHub Actions
  workflow that detect official RouterOS releases, test the candidate CHR image
  in Docker, and open a version/documentation bump pull request only after the
  integration suite passes. Bot branches explicitly dispatch standard CI so
  required checks still run despite GitHub token recursion protection.
- `mikrotik/tests/routeros-version.env` as the canonical CHR compatibility
  version shared by the Docker build, test runner, and automated bump flow.
- `CHANGELOG.md` — this file.
- `CODE_OF_CONDUCT.md` — Contributor Covenant 2.1, reported through the same
  private route as a security issue.
- `docs/good-first-issues.md` — small, verified tasks for a first contribution,
  each naming the file to change and how to check the result.
- A **Why this exists** section in `README.md`.
- A **Repository settings** checklist in `CONTRIBUTING.md` for the settings a
  repository cannot set for itself.

## 2026-08-02

Closing the gaps: repository hygiene, honest CI, and two more packages (#13).

### Added

- `linux/` package: `install_devtools.sh`, `stay_fresh.sh`, `packages.sh`,
  `bash_aliases.sh`, and a Docker suite that **runs** them inside pinned Debian,
  Fedora and Arch images rather than only parsing them.
- `windows/setup/winget_bootstrap.ps1` — `export`/`check`/`import`/`diff` over
  the installed package list, mirroring `brewfile.sh`.
- `windows/tests/contract.ps1` — parse, comment-based help, preview-before-change
  and documented-flags-exist checks over the PowerShell scripts.
- `test-env/static/` — repository-wide convention checks that discover their own
  subjects through `test-env/lib/discover_clis.sh`, so a new script is covered by
  the commit that adds it.
- `git/git_prune_gone.sh`, `git/git_size_report.sh` and
  `git/git_signing_doctor.py`.
- `macos-initial-setup/macos_defaults.sh` — read-only by default, with
  `--apply` and `--revert`.
- `templates/` — working no-op Bash and PowerShell starting points, tracked so
  CI keeps them in step with the conventions.
- `LICENSE` (MIT), `CONTRIBUTING.md`, `SECURITY.md`, issue and pull-request
  templates, `.github/dependabot.yml`, `.editorconfig` and
  `PSScriptAnalyzerSettings.psd1`.
- `.github/workflows/chr.yml` — the RouterOS CHR suite, nightly and on demand,
  off the pull-request path.

### Changed

- `ci.yml` gained a `changes` job that maps a diff onto per-suite flags, pinned
  tool versions with asserted installs, SHA-pinned actions, and step-level rather
  than job-level skipping so required checks always report.
- `run-tests.sh` learned the `linux` and `windows` suites and moved the Docker
  preflight behind suite selection.
- ShellCheck coverage extended to the Git Bash dotfiles, which have no `.sh`
  extension and had gone unchecked.

## 2026-07-31

CI and hardening (#12).

### Added

- `run-tests.sh` — one entry point for every suite, printing a pass/fail/skip
  matrix, called by CI so a local run and a CI run mean the same thing.
- `test-env/python/` — stdlib `unittest` suites for the Python helpers, with no
  Docker, venv or network.
- `git/git_ssh_doctor.py` — read-only diagnosis of
  `Permission denied (publickey)`.
- `macos-initial-setup/brewfile.sh`, `macos-initial-setup/launchd/stay_fresh_agent.sh`
  and `macos-initial-setup/lib/workspace_scan.py`.
- `mikrotik/export_config.py` — pulls `/export` over ssh and versions it, with
  the volatile header stripped so only real changes show up as diffs.
- `pyproject.toml` for the ruff configuration.

## 2026-07-29

- `macos-initial-setup/stay_fresh.sh` learned to prune application caches (#10).

## 2026-07-20

The Windows package and the first CI workflow (#9).

### Added

- `windows/git-bash/` — `.bashrc`, `.bash_profile` and `.aliases`, with one
  shared `ssh-agent` across Git Bash windows instead of one leaked per terminal.
- `windows/wsl/wsl_manage.ps1` — distro list with real VHDX usage, dated `.tar`
  backups, `compact`/`sparse`, shutdown.
- `windows/cleanup/clean_disk_c.ps1` — dry-run-first disk cleanup with
  destructive steps behind opt-in flags.
- `.github/workflows/ci.yml`, `.gitattributes`, `.markdownlint-cli2.yaml` and
  `.yamllint.yml`.

## 2026-05-11

Git helpers, macOS housekeeping and more RouterOS scripts (#6).

### Added

- `git/` package — `gacp.sh`, `set_git_profile.sh`, `git_whoami.sh`,
  `git_status_summary.sh`, `git_sync_default.sh`, `git_cleanup_merged.sh`,
  `git_recent_branches.sh`, `git_repo_root.sh`, `git_diff_branch.sh`,
  `git_undo_last_commit.sh`, `git_amend_last.sh` and `git_aliases.zsh`, with a
  Docker suite that exercises them against temporary repositories and local bare
  remotes.
- `macos-initial-setup/tests/` — Docker static checks for the macOS scripts.
- `mikrotik/dhcp_lease_watch.lua`, `firewall_drift.lua`,
  `firewall_drift_baseline.lua`, `mac_allowlist_dhcp.lua` and
  `rogue_dns_check.lua`.

### Changed

- `macos-initial-setup/stay_fresh.sh` reworked around the labelled `run_cmd`
  dry-run mechanism.

## 2026-04-25

### Added

- `mikrotik/` package — `tg_send.lua`, `backup.lua`, `change_WIFI_pw.lua`,
  `health_check.lua`, `update_check.lua`, `wan_failover_notify.lua`,
  `detect_internet.lua`, `reboot-and-flush.lua`, plus the CHR-under-QEMU test
  harness (#5).

### Changed

- The macOS scripts moved out of the repository root into
  `macos-initial-setup/`, leaving room for the other platforms (#4).

## 2026-04-22

### Added

- `v1_stay_fresh.sh` — the earlier flag-free maintenance flow, kept for
  reference (#2).

### Removed

- `old_stay_fresh.sh`, superseded by `v1_stay_fresh.sh` (#2).

### Changed

- `install_apps.sh` gained a larger curated set, and the README was rewritten
  around installation and configuration (#2, #3).

## 2026-04-21

### Added

- First scripts: `install_apps.sh`, `install_devtools.sh`, `stay_fresh.sh` and
  `zsh_aliases.zsh`, for setting up and maintaining a macOS workstation (#1).
