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

### Added

- `brute_force_block.lua` refuses to act when `BF_MAX_FAILURES` (or the local
  default) is less than 1 — a threshold of 0 would block every source IP that
  appears once in the log. The floor has a CHR behavioural test and a
  convention check on the pull-request path, matching what
  `mac_allowlist_dhcp.lua` already does for an empty allowlist.

### Fixed

- `windows/wsl/wsl_manage.ps1` reported exit `1` on a machine without WSL where
  it means exit `2`. `Write-Error` is a terminating error while
  `$ErrorActionPreference` is `'Stop'`, so the `exit 2` written two lines below
  it was never reached. PowerShell 7.3 and later do the same to a native
  command that exits non-zero, which would have skipped every `$LASTEXITCODE`
  check in the file.
- `templates/new_script.ps1` built its example path from `$env:TEMP`, which is
  undefined off Windows, so the template's own dry run could not run to the end
  anywhere else. It uses `[IO.Path]::GetTempPath()` — the same directory on
  Windows, and defined everywhere.
- `test-env/README.md` credited the Python sandbox with a Docker runner, a
  Dockerfile, a justfile, a dev container and mypy. None of them exist: there
  is a `run.sh`, stdlib `unittest`, and `ruff` when ruff happens to be
  installed. It also implied `chef/` and `go/` were part of the test run —
  `run-tests.sh` has no suite for either and no workflow invokes their
  `just ci`, so a change that breaks a converge is caught by nobody until
  somebody runs it by hand. All three READMEs say so now, along with what CI
  does cover (the scaffolding as text, and not the `Dockerfile`s: there is no
  hadolint step).
- `.github/pull_request_template.md` listed the fast suite selection without
  `k8s`, which `run-tests.sh` has run since the Kubernetes toolbox landed.
- `docs/good-first-issues.md` carried four entries that were already done. The
  premise of that file is that every entry is a real gap, so they moved to a
  short Resolved section instead of sitting there being wrong.
- `macos-initial-setup/tests/test_macos_initial_setup.sh` checked a hardcoded
  list of four scripts while the package had grown to nine, so `brewfile.sh`,
  `macos_defaults.sh`, `workstation_doctor.sh` and
  `launchd/stay_fresh_agent.sh` had no syntax, ShellCheck, `--help` or
  unknown-flag coverage there at all — the omission this repository already
  quotes as a cautionary tale in two other files. It discovers its subjects
  with `find` now, two levels deep so `launchd/` is included, and applies the
  `--help`, unknown-flag and platform-guard contracts to every one of them.
  `zsh_aliases.zsh` stays out of those contracts, because it is sourced rather
  than run, and is still ShellCheck'd and sourced under `zsh`.
- `macos-initial-setup/README.md` documented a `mise self-update` step and a
  `--skip-mise` flag that `stay_fresh.sh` does not have — passing it exits `3`
  — while two steps the script really does run, the per-app cache sweep and the
  VS Code / Cursor workspace-storage prune, appeared nowhere. Both were added
  along with their `--skip-appcaches` and `--skip-workspacestorage` flags, and
  the step list now matches the order the script executes.
- `macos-initial-setup/workstation_doctor.sh` was in the folder and in no part
  of the package README: not the table of contents, not the folder map, and
  with no section of its own while every other script had one. It has all
  three now, as does the new `hardening_audit.sh`.
- `k8s-toolbox/examples/job.yaml` ran `kubectl version --client=true --short`.
  That flag was removed in kubectl 1.28, so against the version this image pins
  the job failed on its first line — a smoke test that could only ever report a
  problem with itself.
- `--dry-run` in `k8s-toolbox/build.sh` and `run.sh` exited `2` when Docker was
  not installed, before printing anything. A preview touches nothing, so it
  should answer on a machine that could not run the real thing; that is the
  same reasoning that puts `--help` ahead of every preflight check. The same
  now goes for `debug_pod.sh` without `kubectl`.
- `k8s-toolbox/run.sh` mounted the kubeconfig at `/home/toolbox/.kube` even
  under `--root`, where `$HOME` is `/root`. The mount was there and the running
  user never looked at it, which surfaces as an unexplained connection refused.
- `--tag` and `--platform` in `k8s-toolbox/build.sh` and `run.sh` were written
  as `"${2:?missing value}"`, which exits `1` where the repository contract says
  a usage error is `3`, and — worse — happily accepts the next flag as the
  value: `--tag --push` built an image tagged `--push` and pushed nothing. They
  use the same `require_value` as the rest of the repository now.
- `k8s-toolbox/build.sh` used the repository root as the build context, so
  every file in the repository was uploaded to the Docker daemon on each build.
  The Dockerfile copies nothing from the context; it is now the package
  directory, trimmed by a `.dockerignore` to the two files that matter.
- The RouterOS version workflow pushed its bump branch with a
  `--force-with-lease` that could never fire. The bare form compares against the
  remote-tracking ref, and the step fetched that ref immediately before pushing,
  refreshing the lease to the current remote tip — so it behaved as a plain
  `--force` and would silently discard a fix hand-pushed onto the bot branch.
  The remote SHA is now read before any local work and passed to the lease
  explicitly.
- The RouterOS version workflow was scheduled at `0 3 * * 1,4`. Minute 0 is the
  contended slot that `chr.yml` was already moved off in #22, and the first
  scheduled run fired at 05:37 rather than 03:00. It now runs at 04:19, on an
  odd minute distinct from the nightly's.
- The root README described the nightly CHR suite as running at 03:00 UTC. It
  has run at 03:37 since #22 moved it off the contended slot; only the workflow
  comment was updated at the time.
- `mikrotik/pull_router_backups.sh` exited `0` when it could not reach the
  router at all. An unreachable host, a rejected key or SFTP switched off in
  IP → Services were indistinguishable from "no backups yet", so a cron job
  reported success while backups silently stopped. It now probes reachability
  first and separates *could not connect* (`2`) from *reached it but the
  transfer failed* (`1`) from *connected, nothing to pull yet* (`0`).
- `mikrotik/update_check.lua` compared installed and latest versions with `!=`,
  which only answers "are these different". Switching a router from the stable
  channel to long-term made `latest` older than `installed`, and the script
  announced it as an available update — advertising a downgrade. It now gates
  on RouterOS's own `status` verdict.
- `mikrotik/backup.lua` had no way to set the backup password except editing
  the tracked script, unlike every other secret in the package. It now reads a
  `BACKUP_PASSWORD` global, matching `tg_send.lua` and `ddns_update.lua`.
- `backup.lua`, `detect_internet.lua` and `update_check.lua` swallowed a failed
  Telegram send with a bare `on-error={}`. A notification that never arrives and
  leaves no log makes the whole package silently decorative; all three now log.
- Twelve RouterOS scripts were missing from `mikrotik/README.md`.
- `--dry-run` created a timestamped log file in five scripts, contradicting the
  first promise in `README.md`. Log creation is now guarded, and the path that
  *would* be written is printed instead.

### Changed

- `windows/tests/contract.ps1` discovers `templates/*.ps1` as well as
  `windows/**`. The templates exist so the conventions cannot drift away from
  them, which only works if the same checks run against them, and
  `new_script.ps1` was covered by repository-wide PSScriptAnalyzer and by
  nothing that read its help or ran it.
- Long-term RouterOS workflow runs are now explicitly check-only; attempts to
  use that channel for the canonical stable version bump fail clearly instead
  of silently reporting an older long-term release as current.
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

- `git/git_remote_doctor.py` — the third read-only diagnostic, covering the
  layer the other two step over: the URL git actually dials, and how it finds
  a password when that URL is HTTP. Three things decide both, and none of them
  is visible in `git remote -v`. The URL itself, where a fetch over ssh with a
  push over https is why a pull is silent and a push prompts, `git://` cannot
  carry a push at all, and a port written after the colon of an scp-like URL
  is a directory name — `git@host:2222/o/r.git` asks for a repository called
  `2222/o/r.git`, and the error saying it does not exist is correct. The
  `insteadOf` and `pushInsteadOf` rewrites, which mean the configured URL is
  not the dialled one, resolved the way git resolves them: longest match wins,
  and one rewrite rather than a chain, so a rewrite whose result matches
  another pattern is reported as the dead end it is. And credential helpers,
  which accumulate across scopes unlike almost every other key, and which a
  single empty value empties — the documented way to ignore a system-wide
  helper, and the undocumented way to lose your keychain by pasting a config
  snippet. Helpers resolve against git's exec path as well as `PATH`, because
  `git-credential-store` lives in `/usr/lib/git-core` and calling it missing
  would be a false alarm on almost every machine. Everything printed is
  redacted first: `https://x-access-token:TOKEN@github.com/` is an ordinary
  rewrite base in CI, and a diagnostic whose output gets pasted into an issue
  must not be the thing that leaks it.
- `git/git_stale_branches.sh` — read-only report of branches nobody has
  touched in `--days` (default 90), oldest first, with the last author.
  `git_prune_gone.sh` only sees branches whose upstream is gone and
  `git_cleanup_merged.sh` only sees branches with a real merge commit; neither
  says how old anything is, and age is what decides whether a branch is worth
  reading at all. Each one is labelled `gone`, `merged` or `unmerged`, so the
  list hands off to whichever script can act on it — `unmerged` being the one
  to read by hand, since squash-merged work and an abandoned branch are
  indistinguishable from here. It does not fetch: a report that quietly
  rewrites remote-tracking refs is not read-only, and the closing notes name
  the command that does. Exits `4` when nothing is older than the threshold.
- `git/git_aliases.sh` — the bash half of `git_aliases.zsh`, sourced the way
  `linux/bash_aliases.sh` is and with the same guard against being run
  instead. Both files now cover the package rather than `gacp` alone, which is
  where the long names are: `git_status_summary.sh`, `git_prune_gone.sh`,
  `git_signing_doctor.py`. Every alias is defined only if its script is
  actually there — beside the file, or on `PATH` for anyone who copied the
  scripts into `~/bin` — because an alias to a script that is not installed
  fails at use time, in the middle of something else, with a message about a
  missing file rather than about the alias. The names avoid the two-letter git
  aliases `linux/bash_aliases.sh` already defines, so one shell can source
  both.
- An opt-in `commit-msg` hook in `git/git_hooks_install.sh`, behind
  `--commit-msg` on install, refusing a subject that is not a Conventional
  Commit. The default install is unchanged and still writes `pre-commit`
  alone: a message convention is a team decision, and a hook that imposes one
  on a repository that has not agreed to it gets `--no-verify`d on its first
  use and then never runs again. Messages git writes itself — merges, reverts,
  `fixup!` and `squash!` — are exempt, because rejecting those breaks a rebase
  rather than improving a changelog, and the subject is taken as the first
  line that is neither blank nor a comment, so a message written under
  `commit.verbose` or from a template is judged on the line the author wrote.
  `status` and `uninstall` handle both hooks, versioned separately so adding
  this one does not report every existing installation as out of date.
- `windows/wsl/wsl_manage.ps1` gained four actions and a `-DryRun` switch.
  `restore` imports a `.tar` back as a new distro and checks the two things
  that make `wsl --import` surprising before it starts: the name has to be
  free, because import cannot replace a distro in place, and the restored copy
  boots as root, because the default user is recorded inside the distro and is
  not carried over. `df` puts a number on the question `compact` exists for —
  the VHDX file on the Windows side against `df` inside the distro, with the
  gap between them being what compacting would give back; measuring a stopped
  distro starts it, so that stays behind `-Force` rather than happening in a
  read-only report. `terminate` stops one distro where `shutdown` stops all of
  them and the utility VM with them. `prune-backups` applies age and count
  retention to the export folder, which otherwise accumulates full filesystem
  copies nobody deletes: it considers only files named the way `backup` writes
  them, prints the `KEEP`/`PRUNE` list first, and asks before deleting unless
  `-Force`.
- `templates/new_helper.py` — the starting point for a Python helper, the one
  shape in this repository that had no template. It is a working no-op in the
  form the existing helpers share: standard library only and 3.9-clean because
  `/usr/bin/python3` on macOS is 3.9, `argparse`, colour behind a
  terminal-and-`NO_COLOR` guard, read-only because a diagnostic prints the
  command that fixes the problem rather than running it, and pure functions
  that take the `PATH` string and the command output as parameters so their
  tests are fixture data rather than a description of the machine they ran on.
- `windows/tests/contract.ps1` runs every `-DryRun` script as a child process
  against a scratch `HOME` and `TEMP` and fails if the filesystem changed —
  the assertion `test-env/static/check_conventions.sh` already makes for the
  Bash scripts, for the reason recorded there: reading a script's own claim
  that it changed nothing proves nothing. On Windows that exercises the whole
  dry-run path. On Linux the subjects stop at their platform check, which is
  still where a stray log file or scratch directory would appear, and the
  template runs its dry run to the end anywhere.
- `linux/system_doctor.sh` — the Linux counterpart of
  `macos-initial-setup/workstation_doctor.sh`, and the narrative half of a pair
  with `hardening_audit.sh` next to it. The audit asks whether a machine is
  safe and grades what it finds; this asks whether it is well and describes it:
  distribution and uptime, which package manager owns the box and how old its
  index is, free space, a pending reboot, sshd, failed `systemd` units, which
  host firewall is in charge, container engines, and load per core. Three of
  its checks exist because the ordinary tools hide them — inode exhaustion
  looks completely healthy in `df -h`, a package index months out of date makes
  a machine report itself current, and a container engine that is installed but
  unreachable is indistinguishable from one that is not installed until you try
  to use it. It never returns `1`: gating a pipeline is what
  `hardening_audit.sh --fail-on warn` is for, and duplicating that here would
  only give two answers to one question.
- `macos-initial-setup/hardening_audit.sh` — the macOS half of
  `linux/hardening_audit.sh`, with the same flags (`--only`, `--fail-on`,
  `--quiet`, `--list-groups`) and the same exit codes. Six groups: sharing
  services, the Application Firewall and its stealth mode, the software-update
  settings, FileVault, SIP and Gatekeeper. Like its Linux counterpart it has no
  `--apply`, because every finding has a context where the insecure-looking
  answer is the right one. The sharing checks ask `netstat` which ports are
  listening rather than `systemsetup`, which needs root: an audit you have to
  `sudo` is an audit nobody runs. Loopback-only listeners are ignored, so an
  ssh tunnel endpoint on `127.0.0.1` is not reported as File Sharing being on.
- `k8s-toolbox/versions.env` pins `yq`, `kubectl`, `helm`, `kustomize` and
  `gcloud`, and is now the only place those versions are written down.
  `build.sh` passes each one as a build ARG and the Dockerfile asserts the
  version it actually installed, so a moved release or a redirected download
  fails the build instead of quietly shipping something else. I also replaced
  the Google Cloud SDK's `curl … | bash` installer with its versioned tarball:
  the convenience script always fetches the current release, which would have
  made the pin decorative — and piping an installer into a shell is a posture
  this repository takes nowhere else.
- `k8s-toolbox/kubectl_pod_diag.sh` — read-only cluster triage in one pass:
  pods that are not Running, plus Running pods whose containers are in
  `CrashLoopBackOff` or `ImagePullBackOff`, because a pod can be Running and
  completely broken. Then the last hour of `Warning` events, unbound PVCs, and
  nodes reporting memory, disk or PID pressure. For a crash-looping pod it also
  prints the *previous* container's logs, which is where the reason is — the
  current one has usually not got far enough to say anything. "Nothing found"
  exits `4` rather than `0`, so a scheduled check can act on the code instead
  of parsing output.
- `k8s-toolbox/debug_pod.sh` — wraps `kubectl debug` to attach the toolbox
  image to a running pod as an ephemeral container. This is what I wanted the
  first time I met a distroless container with no shell in it: the application
  keeps running, nothing about it is modified, and `--target` shares its
  process namespace so its `/proc` is visible.
- `k8s-toolbox/tests/`, wired in as the `k8s` suite in `run-tests.sh` and CI.
  It checks contracts and deliberately does not build the image: five pinned
  toolchains fetched from five hosts is minutes of network per run, and what
  regresses is the scripts that drive the build, not the build. So it needs
  nothing but bash and runs everywhere the conventions suite does, including
  in front of a pull request. It covers `--help`, unknown flags, flags given no
  value, the dry-run promise checked against the filesystem rather than against
  the script's own claim, and exit `2` when Docker or `kubectl` is missing —
  arranged by emptying `PATH` down to a single symlink to bash, since the
  runner has both installed. It also holds `versions.env`, the Dockerfile's
  `ARG`s and `build.sh` to agreement: a version pinned in one of the three but
  missing from another is a pin with no effect, which is worse than no pin.
  `K8S_IMAGE_SMOKE=1` opts into the real build and asserts the container runs
  as uid 1000 with every CLI on `PATH`.
- `k8s-toolbox/examples/kustomization.yaml` retags the example manifests
  instead of editing them. They name `k8s-toolbox:local`, which exists only on
  a machine that has run `build.sh`; anyone pushing to a registry had to
  hand-edit two files or keep a `sed` line in a runbook.
- The `k8s-toolbox/` example manifests now pass the **restricted** Pod Security
  Standard unchanged — an explicit non-root uid, all capabilities dropped, the
  `RuntimeDefault` seccomp profile, requests and limits — and no longer mount a
  service-account token. An example is the file that gets copied, and a
  debugging shell that can reach the API server as the namespace default
  service account is a larger hole than whatever it was opened to investigate.
  `readOnlyRootFilesystem` is the one thing left off, with the reason written
  down: `gcloud` writes to its config directory on first use, and a toolbox
  that cannot run `gcloud auth` is not a toolbox.
- `mikrotik/print_schedulers.sh` — prints the `/system scheduler add` command
  for every RouterOS script here that is meant to run unattended, ready to
  review and paste. Installing a script is the easy half; scheduling it is where
  the package went quiet, because a script nobody scheduled looks exactly like a
  script with nothing to report, and you find that out in the month you needed
  the backup. Twenty scripts are meant to run on a timer and only eight had an
  interval written down — the other twelve take the one already named in their
  own header comment. It contacts nothing, writes nothing, and emits valid
  RouterOS input including its commentary, so the output can be kept in a file
  and diffed later.
- `mikrotik/router_doctor.py` — read-only audit over ssh of which scripts are in
  `/system script`, which of them a `/system scheduler` entry actually runs, and
  whether the globals they need are set. A script installed under the wrong
  name, a script scheduled nowhere and an unset `TG_BOT_TOKEN` all look
  identical to a router with nothing to report. The globals check asks the
  router for the *length* of `TG_BOT_TOKEN` and `TG_CHAT_ID` and never for the
  value, so the report can say set or empty without a token crossing the wire.
  A script that is simply not installed is reported as context rather than as a
  problem — nobody wants `ddns_update` without Cloudflare.
- `mikrotik/tests/test_lua_conventions.sh` now checks the scheduler coverage in
  both directions: every unattended script has a line in `print_schedulers.sh`,
  and none of the manual-only ones does. Putting `reboot-and-flush` on a timer
  is a surprise nobody wants twice.
- `windows/setup/stay_fresh.ps1` — the Windows counterpart of
  `linux/stay_fresh.sh` and `macos-initial-setup/stay_fresh.sh`, down to the
  exit codes: a winget source refresh and `upgrade --all`, `wsl --update`, and
  a pending-reboot and free-space report, with `-DryRun` printing the whole run
  before any of it happens. `--include-unknown` is passed deliberately —
  without it winget skips every package whose installed version it cannot read,
  which is the usual reason a machine reports itself up to date and is not.
  Microsoft Store apps are left alone on purpose: their agreements have to be
  accepted interactively, so an unattended run cannot honestly claim to have
  updated them, and the script prints the command that does instead.
- `windows/setup/workstation_doctor.ps1` — the Windows half of
  `macos-initial-setup/workstation_doctor.sh`. BitLocker, Defender, the
  pending-reboot flags, free space on `C:`, WSL and its distros, and the
  effective execution policy, all read-only, which makes it the safe first
  thing to run on a machine someone has just handed you. Every probe is
  best-effort, because `Get-BitLockerVolume` does not exist on Home editions
  and `Get-MpComputerStatus` is missing wherever Defender has been replaced:
  a probe that cannot answer says so and the report carries on rather than
  dying before the section you needed.
- `windows/git-bash/install_dotfiles.sh` — copies `.bashrc`, `.bash_profile`
  and `.aliases` into `$HOME`, with the two checks the README's plain `cp`
  cannot do for you. It backs up whatever it replaces under one timestamp per
  run, leaves a file that already matches the source alone, and refuses to
  install a source file carrying CRLF line endings — printing the `sed` that
  fixes it rather than rewriting a file you are about to live in. CRLF in the
  file being replaced is reported too; that is usually the answer to the
  broken-prompt syntax error in the troubleshooting section.
- `windows/setup/winget-packages.example.json` — a worked example of what
  `winget_bootstrap.ps1 export` writes, so the `import`/`diff` documentation
  can be read without a Windows machine to hand. The same part
  `Brewfile.example` plays next to `brewfile.sh`, and it is a valid import
  file: `import -DryRun -File .\winget-packages.example.json` works against it.
- `linux/systemd/stay_fresh_timer.sh` — the Linux counterpart of
  `macos-initial-setup/launchd/stay_fresh_agent.sh`: `install`, `uninstall`,
  `status` and `run-now` for a `systemd` user timer that runs `stay_fresh.sh`
  on a schedule. The generated units are checked with `systemd-analyze verify`
  before anything is written, the way the macOS script lints its plist, and
  `--print-only` renders them without installing. Like the timer itself, the
  unit has no terminal to answer a sudo prompt from, so it always passes
  `--yes --no-sudo`.
- `linux/tests/test_linux_scripts.sh` now discovers scripts two levels deep, so
  anything under `linux/systemd/` gets the same `bash -n`, `--help` and
  unknown-flag coverage as the top-level scripts without being listed by hand.
- `mikrotik/tests/test_lua_conventions.sh` — RouterOS script conventions checked
  without a router, so they run on the pull-request path rather than waiting for
  the nightly CHR suite. 14 of the 25 scripts had no test of any kind, and a
  batch of twelve had landed with neither tests nor a README entry.
- `test-env/static/check_conventions.sh` asserts "a dry run writes nothing"
  against the filesystem for every `--dry-run`-capable CLI, running each under
  a scratch `HOME` and `TMPDIR`. The previous check read the script's own
  "no changes written" output, which stayed green while files were created.
- `mikrotik/tests/test_pull_router_backups.sh` — exit-code contract driven with
  ssh/scp stubs, so it needs no Docker, network or router and runs on the
  pull-request path.
- `ROUTEROS_SHA256` in `mikrotik/tests/routeros-version.env`, checked during
  the CHR image build. The image boots as a kernel with the repository mounted
  and was previously validated only as "non-empty", which a hijacked mirror or
  a TLS-terminating proxy also satisfies. The digest for 7.23.3 is recorded, and
  `mikrotik/tests/run.sh` now refuses to start without one rather than warning
  and continuing: a version bump hashes the new archive before it moves the
  version, so an empty value can only mean the pin was lost. Record or refresh
  it with `mikrotik/tests/routeros_version.py record-hash`.
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
