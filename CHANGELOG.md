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

- Dependabot watches the Docker base images as well as the actions. Every suite
  that runs anything builds it on one, and they were watched by nothing — the
  same mutable-tag argument the actions entry already makes, applied to the
  images the tests stand on. The entry globs directories rather than listing
  them, so a Dockerfile added later is covered by the commit that adds it.
  Coverage is partial by nature: Dependabot compares version-like tags, so
  `alpine`, `python`, `ruby` and `golang` move, `debian:bookworm-slim` is a
  codename with nothing to compare, and `linux/tests/tester` takes its base
  from a build argument that has no literal to read.

- Drift checks between the package READMEs and the scripts beside them, in
  `test-env/static/test_doc_citations.sh`. Both directions have failed here
  before: a batch of twelve RouterOS scripts landed with no README entry, which
  is why that package grew its own check, and a section heading for a deleted
  script outlives the script with markdownlint reporting nothing. Every script
  in a package must be named in that package's README, and a README section
  naming a script must have a script to name, and a script with no package
  README above it fails rather than dropping out of coverage — a new package,
  or one whose README was deleted, took its scripts with it. 88 scripts across
  13 packages pass today, so the rule needs no exemption list.

  A script belongs to the nearest README above it, not to every README above
  it: git pathspec globs cross directory boundaries, so a first draft held
  `windows/README.md` to naming the eight scripts under its subdirectories and
  counted each of them twice. Packages are discovered rather than listed,
  because a hardcoded package list is the thing that rots — the macOS suite's
  hardcoded script list is how `launchd/stay_fresh_agent.sh` stopped being
  covered. The repository root is excluded: `README.md` is an index of
  packages, and holding it to "name every script beside you" would mean every
  script in the tree.

- `stay_fresh.sh --only ai-caches` clears disposable Claude, Codex, ChatGPT,
  Cursor, and Windsurf caches without treating all AI data as temporary. It
  skips a tool while its process is active, fails closed when process state
  cannot be inspected, and preserves credentials, settings, conversations and
  project sessions, extensions, Codex runtimes, and local models. The
  LaunchAgent's conservative profile includes the step, so these caches are
  handled on schedule without broad user-cache deletion.

- Task-scoped conventions under `.claude/skills/` on a local checkout, so an
  automated coding agent working here loads the rules for the file in front of
  it instead of skimming `CONTRIBUTING.md` and acting on the half it remembered.
  Ten skills: one entry point, one per language (`bash`, PowerShell, RouterOS,
  Python), and one each for adding a script, running the suites, the pre-push
  lint gates, documentation and the changelog, and commits and pull requests.
  The directory is gitignored and is not on GitHub; `CONTRIBUTING.md` stays the
  published reference.

  Nothing in them is new policy — every rule is lifted from a script or from
  the check that enforces it, and each skill names that check, because a rule
  documented away from its enforcement is the one that drifts. The failures
  that shaped this repository are stated as failures: the preview that wrote a
  log file, the `install --dry-run` that wrote two systemd units, the
  PowerShell dry run that was only ever exercised on a platform where it exits
  at a guard.

- `stay_fresh.sh --prune-docker-volumes`. Volume pruning was part of the
  default Docker step; volumes hold data, not cache — a stopped project's
  database volume counts as "unused" the moment its container is removed, and
  the LaunchAgent runs the script with `--yes`, so every scheduled run deleted
  such volumes unattended. Containers, networks, dangling images and builder
  cache still prune by default; volumes now need the flag, and the plan line
  says which of the two the run will do.

- Two Docker suites that run `stay_fresh.sh` for real, which the existing
  `tester` job never did. `test_macos_initial_setup.sh` covers `--help`,
  argument rejection, plans and dry runs; a step that deletes things was
  unreachable there, so a sudo keep-alive that blocked captured callers, a
  TTY check that asked `access(2)` instead of opening `/dev/tty`, and a lock
  that blamed a missing `TMPDIR` on a stale run all reached `master`.

  `test_stay_fresh_steps.sh` executes each of the sixteen steps against a
  scratch `HOME` and faked host binaries; `find`/`rm`/`du` are the real thing,
  so the assertions are about what survived. It refuses to start outside a
  container because two of those steps clear `/Library/Caches` and
  `/Library/Logs/DiagnosticReports`. `test_stay_fresh_unprivileged.sh` runs as
  uid 1000 against root-owned `/rootonly` and `/rootlocked`, the only way to
  make `mkdir(2)` and `unlink(2)` actually return `EACCES`.

  `macos-initial-setup/tests/run.sh` now builds once and runs all three, even
  if an earlier suite fails. It passes `compose run -T`: without that, a host
  with a TTY hands the container a controlling terminal, which is the state a
  launchd job is not in, and the cask-skip assertion would pass for the wrong
  reason.

- DevOps coverage in `macos-initial-setup/zsh_aliases.zsh`: the kubectl
  section grows from six aliases to the working set (`kgp`/`kgpa`/`kgs`/`kgd`/
  `kgn`, `kaf`, `kdelf`, `kpf`, `krr`/`krs`, `ktop`, `kev` sorted by the time
  things actually happened, and `kdry` for a server-side dry run that goes
  through real admission), a `kctx` show-or-switch helper, new aws
  (`aws-whoami`, `awsp` profile switcher) and ansible (`ap`, `apc`
  check-with-diff, `av`, `ainv`) sections, `docker stats`/container-IP
  helpers, `terraform state show`, a `retry` function with exponential
  backoff that preserves the failing command's exit code, alias-aware
  `sudo`/`watch` (trailing space, so the next word alias-expands), completion mapped onto the short aliases when the user's
  own `compinit` has run, and history timestamps (`EXTENDED_HISTORY`) so
  "when did I run that apply" has an answer.

  Two shadows were removed rather than added: `find` is no longer aliased to
  `fd`, and `grep` no longer to `rg` (in `linux/bash_aliases.sh` too). The
  flags differ - `find . -name` errors under fd, `grep -rn pattern dir`
  changes meaning under rg - so a command copied from a runbook broke exactly
  on the machine that had the alias. Both tools keep their own names. Also
  fixed: `localip` was registered on every OS but called macOS-only
  `ipconfig`; on Linux it now reads the `src` token from `ip route get`
  (scanned, not counted - the field number shifts when the route has no via
  hop). The dead `py2` alias is gone.

  The suite now asserts the shadows stay gone (as text, because the aliases
  were guarded - in a container without fd installed a behavioural check
  passes whether or not the shadow exists), that `sudo` keeps its trailing
  space, and `retry`'s exit-code contract; all three fail against the
  previous file.

- The RouterOS bump can push its branch. `GITHUB_TOKEN` is refused when it
  pushes a branch touching `.github/workflows/`, and that permission cannot be
  granted from a workflow's own `permissions:` block - it is not one of the
  keys GitHub accepts there. `chr.yml` named the pinned version in a prose
  comment, and that one number was enough to put a workflow file in the bump's
  edit set, so the branch push was rejected after the CHR suite had already
  passed.

  The comment no longer names a version and points at
  `mikrotik/tests/routeros-version.env` instead, which is the pin. Two tests
  keep it that way: no workflow path may appear in `DOCUMENTATION_FILES`, and
  no workflow file may contain the pinned version. Both fail if either is
  reintroduced.

- The RouterOS bump step can find its insertion point. It required the literal
  `## [Unreleased]\n\n### Changed\n\n`, so `### Changed` had to be the *first*
  subsection under Unreleased. This changelog has never been shaped that way,
  which means the bump could not have run even after the candidate test was
  fixed - an ordinary `### Added` entry above it was enough to stop the release
  automation, and it failed in under a second with a message about a missing
  insertion point.

  The section is now located wherever it sits, and created in Keep a Changelog
  order when absent. Two of the three regexes involved used `\s*` to match the
  end of a heading line, which is greedy across newlines and left the caller
  reinserting blank lines that were already there - producing `MD012` and a
  bump whose own commit turned the repository red. They match `[ \t]*` now.

  Seven changelog shapes are covered, each checked for the entry, for markdown
  that lints clean, and for joining the existing list rather than splitting it.
  Ten of them fail against the previous implementation.

- The RouterOS candidate test can pass. It never could: the workflow overrode
  `ROUTEROS_VERSION` to the candidate but left `ROUTEROS_SHA256` at the pinned
  version's digest, so the CHR build downloaded the new archive and verified it
  against the old one's hash. Every candidate failed its checksum, which reads
  like a supply-chain alarm and is exactly what `bump_version`'s docstring
  warns about - the guard was on the bump path but not on the test that runs
  before it.

  `record-hash --print` resolves a digest without rewriting the pin, which is
  what check-only mode needs. `run.sh` already preferred an exported
  `ROUTEROS_SHA256` over the file, so that seam is all the workflow was
  missing. `bump --digest` then pins the digest the test actually ran against
  instead of re-downloading, so a republished artifact cannot pin bytes nothing
  has booted.

  This is a first observation of the candidate's digest, not an independent
  verification - nothing publishes a checksum to compare against. It catches a
  truncated download and a mirror serving two different bodies; it becomes a
  real anchor when the bump commits it.

  Confirmed against the live feed on a manual `check_only` run, which also
  showed the multi-channel RSS fix working: `pinned 7.23.3, candidate 7.24`.

- Two Windows checks that run on Linux, where the whole class was previously
  invisible. Every script under `windows/` exits at its `$IsWindows` guard
  before its preview runs, so `./run-tests.sh windows` was silent about what
  the preview does - which is how a Chocolatey dry run that wrote two
  directories reached `master`, and how an em dash reached it before that.

  `windows/tests/contract.ps1` now rejects non-ASCII bytes and a UTF-8 BOM in
  any `.ps1`, naming the line, and asserts that a preview never invokes its
  packaging tool. The second runs the script with the platform guard removed
  from a copy and the tools replaced on `PATH` by shims that record being
  called. If the guard text ever stops matching, the check fails loudly rather
  than skipping - a harness that quietly stops transforming is one that quietly
  stops checking.

- Review pass over the WinGet migration, fixing four defects in it and closing
  the gap that let the worst of them through.

  The OS assertion in `configuration.winget` demanded build `10.0.22000` while
  describing itself as "Windows 10 21H2 or newer". `10.0.22000` is Windows 11
  21H2; Windows 10 21H2 is `10.0.19044`. Every Windows 10 machine would have
  failed the assertion and been told it needed a version it already had. The
  floor stays at Windows 11 - Windows 10 left support in October 2025 - and the
  description now says so.

  `winget_configure.ps1 apply -DryRun` accepted a directory as `-File` and
  surfaced a raw `Get-Content` exception instead of a usage error, and printed
  "would apply" and exited 0 for an empty file or one pointed at the wrong
  YAML. A preview that cannot say what it would do has failed. Both are now
  refused, with 3 for a bad path and 1 for a file declaring no resources.
  `winget_bootstrap.ps1` had the same directory-as-a-file hole in four places.

  The winget presence and version checks moved to the point of invocation, so
  `apply -DryRun` no longer requires App Installer to be present. Previewing a
  configuration is the first thing worth running on a fresh machine, and it
  reads the file rather than asking winget anything.

  Nothing validated `configuration.winget` at all: `yamllint .` discovers only
  `*.yml` and `*.yaml`. It is now named in `yaml-files` and covered by the
  change filter. Syntax alone is not enough, though - an unquoted description
  containing a comma ends its value inside an inline map and turns the
  remainder into a directive key nobody wrote, producing valid YAML and the
  wrong document. `test-env/static/winget_config_shape.py` checks the shape:
  resources present, ids unique, no unknown directive keys. Verified against a
  reconstruction of that exact bug, on which yamllint reports nothing. The
  resource maps are also block-style now, where a comma is harmless.

- `choco_bootstrap.ps1 install -DryRun` no longer calls Chocolatey. It asked
  the machine which packages were missing, and `choco list` creates
  `%TEMP%\chocolatey` and touches `%APPDATA%` doing it - so the preview wrote
  two directories while printing that it had written none. It now reads the
  `packages.config` and reports what the file asks for; `check` still answers
  the missing-package question and is allowed to talk to Chocolatey.

  Caught by the `windows-2025` contract job, not locally: on Linux the script
  exits at its `$IsWindows` guard before the preview path runs, so the whole
  class of bug is invisible to `./run-tests.sh windows` there. `winget --version`
  measured writing nothing on the same runner, but `winget_configure.ps1` now
  defers its version preflight to the point of use anyway, so its preview
  invokes nothing at all.

- `windows/setup/configuration.winget` and `winget_configure.ps1`, making
  winget the primary Windows package manager: a curated, reviewed, declarative
  list of what a workstation should have, applied with `winget configure`. The
  verbs are `validate` / `show` / `test` / `apply`, and `test` reports drift
  through an exit code the same way `winget_bootstrap.ps1 check` and
  `brewfile.sh check` do, so all three drive the same automation.

  This is a complement to the export, not a replacement: the configuration is
  the intent, `winget-packages.json` is the fact. The list is the ported
  Chocolatey one curated down to 18 - ConEmu gives way to Windows Terminal,
  Lightshot to ShareX, two password managers to one, three JVMs to one LTS -
  and it deliberately omits Linux tooling that belongs in WSL, VS Code
  extensions that are not applications, and Chocolatey's own tooling.

  The schema is `0.2` rather than v3 on purpose: v3 requires WinGet 1.11+ with
  the `dscv3` processor, a much narrower floor than this repository targets,
  and a machine below it fails with a DSC error rather than a clear one. The
  preflight checks `winget --version` against 1.6 and exits 2 with the reason.
  Chocolatey stays as the documented fallback for packages winget lacks and for
  machines already managed with it.

- `k8s-toolbox` now has a `debug` image stage, selected with
  `build.sh --variant debug`, tagged `k8s-toolbox:debug` by default.
  It adds tcpdump, strace, htop and the other in-pod network/process
  tools as Debian packages, without putting them in the default image.
  Manifests live in `k8s-toolbox/debug/` and add `NET_RAW`,
  `NET_ADMIN` and `SYS_PTRACE`; `examples/` still pass restricted PSS.

- `ETC_SSH` in `linux/hardening_audit.sh`, the seam `SYSCTL_D` and `PROC_SYS`
  already give `sysctl_defaults.sh`. The SSH checks read a real directory, and
  no tester image installs `openssh-server`, so the host-key grader was the one
  part of this audit nothing ever executed — which is how it shipped a rule that
  failed every stock Fedora host, and then a rule that passed a host whose
  `ssh_keys` group had members. The suite now drives that grader through 600,
  400, 644 and 640 and asserts the hint names the objection that applies. The
  Fedora exemption itself needs a real empty `ssh_keys` group, so it runs only
  where the image has one and prints that it is unverified where it does not.

- CI now runs macOS contracts with Apple Bash on a native `macos-15` runner and
  Windows Git Bash/PowerShell contracts on a native `windows-2025` runner,
  alongside the existing portable Ubuntu/Docker coverage.
- Pinned actionlint and Hadolint gates cover GitHub Actions workflows and every
  tracked Dockerfile. A separate schema job validates Kubernetes examples with
  kubeconform, Kali cloud-init user data with cloud-init itself, and all Docker
  Compose models with `docker compose config`.
- A weekly and manually dispatchable Kubernetes image smoke builds the real
  toolbox image and verifies every pinned CLI. Image and CI tool downloads
  retry transient failures, while the slow five-host build stays off the
  pull-request path.
- `linux/tls_expiry.sh` — read-only leaf certificate expiry for named PEMs
  (`--file`) and hostnames (`--host`), the counterpart of
  `mikrotik/cert_expiry_watch.lua`. It does not walk `/etc/ssl/certs`.
  `--fail-on expired` (default) exits `1` only when a cert is already dead;
  `--fail-on warn` also fails inside the `--days` window. Missing `openssl`
  is exit `2`; `--help` still works without it.
- `linux/config_backup.sh` — dated tar of selected paths (default `/etc`)
  with `--dry-run` / `--yes` / `--dest` / `--keep`. A copy, not a restore:
  it never writes back into the paths it archives. `/` is refused.
- `linux/ssh_client_doctor.sh` — read-only `~/.ssh` modes and `IdentityFile`
  paths. `hardening_audit.sh` grades sshd and does not look here;
  `git/git_ssh_doctor.py` asks `ssh -G` and is not duplicated. `--ssh-dir`
  is the test seam.
- `linux/README.md` has a lifecycle table matching
  `macos-initial-setup/README.md`, so "when to run what" lives next to the
  scripts instead of in a roadmap that would rot.
- `linux/schedule_report.sh` — read-only inventory of systemd user and system
  timers, the user crontab, and the distro `cron.d` / `cron.{hourly,daily,weekly,monthly}`
  drop-ins. A missing scheduler is a skip, not a failure, so the report stays
  green in a container.
- `linux/bash_aliases.sh` now defines hyphenated aliases for every script in
  the folder that is sitting next to it (`stay-fresh`, `system-doctor`,
  `disk-cleanup`, …) and a `toolbox-help` function that lists only the ones
  that are actually executable, matching `macos-initial-setup/zsh_aliases.zsh`.
  Running the file directly points at `install_aliases.sh` instead of the
  echo one-liner that appends a second copy.
- `.github/ISSUE_TEMPLATE/config.yml` — `blank_issues_enabled` is on
  deliberately, with a `contact_links` entry that points at the private
  security advisory form, so the New issue page is not the place a destructive
  script gets reported.
- `git/README.md` has a table of contents covering every `##` heading.
- `git_size_report.sh --fast` is now a behavioural test: it still prints
  on-disk totals, skips the history walk, and exits `0`.
- `linux/install_aliases.sh` — installs the `bash_aliases.sh` source block
  into `~/.bashrc` as a marked pair of comments, so a second run does not
  append a second copy and `--uninstall` can take the block back out without
  touching anything else. The README one-liner that `echo`s a source line
  had both of those failure modes. `--status` reports `MATCH` / `DRIFT` /
  `MISSING`; `--source` is the seam for a copy that no longer sits next to
  the aliases file.
- `linux/disk_cleanup.sh` — the Linux counterpart of
  `windows/cleanup/clean_disk_c.ps1`. `stay_fresh.sh` is weekly maintenance
  and will upgrade packages; this is "I need space now". Default targets are
  user-owned temp files older than `--days` and thumbnail caches. Trash,
  journal vacuum, package caches, pip/npm/go caches and `docker`/`podman`
  prune stay behind `--include-*` flags, and volumes are never pruned. A
  real run requires `--yes`; `--tmp DIR` replaces the default temp list so
  a test (or a machine whose `/tmp` is not disposable) can point at one
  directory.
- `linux/net_doctor.sh` — read-only network report that fills in what
  `system_doctor.sh` leaves out: interface operstate, the default IPv4
  route (from `ip` or `/proc/net/route`), nameservers, listening sockets,
  and an optional `--probe HOST`. Warnings do not change the exit code. The
  probe is off by default so a container with no uplink does not hang the
  report.
- `linux/sysctl_defaults.sh` — the counterpart of
  `macos-initial-setup/macos_defaults.sh` for a short sysctl list: inotify
  watcher/instance/queue ceilings that IDEs exhaust, and
  `vm.swappiness=10` for a workstation. Read-only until `--apply`, which
  writes `/etc/sysctl.d/99-ops-toolbox.conf` and applies live; `--revert`
  restores the backup. `SYSCTL_D` and `PROC_SYS` are honoured so the apply
  path is testable without writing into `/etc`.
- Automation-friendly selection and reporting across the active Git, macOS,
  Linux, Kubernetes, Windows, and RouterOS helpers: scoped `--only` operations,
  machine-readable or quiet diagnostics, read-only inventories and log views,
  and safer branch/profile workflows. Each new surface keeps the existing
  default behavior and is covered by package-level contract tests.
- Kubernetes runtime support for writable, container-private gcloud state
  staged from a read-only host credential directory, custom non-TTY pod debug
  commands, configurable event lookback, and an end-to-end wrapper smoke path.
- Windows backup integrity checks with SHA-256 sidecars, read-only dotfile and
  package status commands, maintenance scopes, and structured PowerShell
  template results that cannot report failed deletion as success.
- A RouterOS maintenance pause for unattended scripts, structured doctor
  output, safe backup transport options, scheduler selection, and read-only
  configuration diffs. Manual recovery and baseline helpers remain available
  while scheduled automation is paused.
- `run-tests.sh --list` and `--summary-file` for CI orchestration, including a
  stable JSON suite/status/duration/exit-code matrix.
- `brute_force_block.lua` refuses to act when `BF_MAX_FAILURES` (or the local
  default) is less than 1 — a threshold of 0 would block every source IP that
  appears once in the log. The floor has a CHR behavioural test and a
  convention check on the pull-request path, matching what
  `mac_allowlist_dhcp.lua` already does for an empty allowlist.
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

### Fixed

- A documentation audit against the scripts, run as a reader test rather than a
  proofread: answer a newcomer's questions from the documents alone, then check
  each answer against the code. Twenty-odd claims did not survive it, and none
  were catchable by CI — the citation check, the README drift check and
  markdownlint all pass on text that says the wrong thing.

  The ones that would have cost someone real time: `mikrotik/README.md` named
  `dns.cloudflare.com` as the `rogue_dns_check.lua` control host, which the
  script moved away from because it false-alarms on a healthy resolver;
  `windows/wsl/README.md` said a backup with no `.sha256` sidecar restores with
  a warning, when it is refused outright; and the quick start told a newcomer to
  copy a template, `chmod +x` it and run the static suite, which discovers its
  subjects from the git index and therefore checks an unstaged script zero times
  while reporting a pass. `git add` is now in the recipe with the reason beside
  it.

  Four exit codes were wrong: `v1_stay_fresh.sh` invalid arguments is `3` not
  `2`, `system_doctor.sh` is not "always `0`", the `linux/` table had no row for
  the `4` that `install_aliases.sh --status` returns, and the two package
  bootstrappers on Windows do not share exit codes the way their READMEs
  claimed. Several blanket quantifiers were majorities rather than rules —
  "each script reads `/etc/os-release`" is five of fourteen, "every non-trivial
  script writes a log" is four of eight, "every script stops at its
  `$IsWindows` guard" is five of seven — and are now scoped to the scripts they
  describe. Around twenty flags and environment variables that the scripts
  accept were documented nowhere, including the mandatory `ROUTEROS_SHA256`,
  whose absence made the candidate-testing recipe fail on a checksum mismatch.

  `CONTRIBUTING.md` gains the "Adding a script" checklist that `README.md` has
  been pointing at, including which of its steps CI enforces and which two are
  kept by reading: the package README entry is checked both directions, the root
  README row is checked by nothing because the citation check excludes the
  repository root, and the `set` dialect and dry-run grammar are checked by
  nobody, which is why the template ships the `git/` pair and has to be adjusted
  by hand outside `git/`.

- `CONTRIBUTING.md` called the `linux/` dry-run output one script's lapse and
  named `stay_fresh.sh` as the offender. All eight `linux/` scripts that take
  `--dry-run` print `git/`'s closing summary line and six also print the
  indented preview above it, so the deviation was the package's norm rather
  than one file's mistake. The section now documents three grammars, with a
  rendering taken from a real `run_cmd` call, and names the two scripts that
  do deviate: `config_backup.sh` previews through `info()` without the indent, and
  `packages.sh` mixes in the `dry-run: would run:` form the same section
  forbids — with a `printf` missing its trailing newline, so the summary is
  glued onto it. It also no longer claims the suite enforces the closing line;
  the four assertions name three scripts individually, and a new script
  omitting it would pass.

- LaunchAgent options are command-scoped. `uninstall --dry-run` is a real
  no-write preview, while ambiguous combinations such as `run-now --dry-run`
  fail with exit `3` instead of silently ignoring the flag.
- LaunchAgent installation stages and validates its plist atomically, checks
  bootout/write/removal failures, and restores the previous plist and loaded
  job when replacement bootstrap fails.
- Docker pruning now fails closed when the active context or endpoint cannot be
  resolved, instead of treating an inspection error as permission to prune.
- `brute_force_block.lua` never reached its default threshold: the tally stored
  `;IP:COUNT;` but looked up `;IP;`, so every failure was recorded as a fresh
  count of 1. The lookup key now includes the colon. A shrink in `/log` (ring
  buffer rotation) also resets the scan cursor instead of skipping the shortened
  log forever.
- `rogue_dns_check.lua` defaulted the control hostname to `dns.cloudflare.com`,
  which does not resolve to `1.1.1.1` / `1.0.0.1` and false-alarmed on a healthy
  resolver. The default is now `one.one.one.one`.
- `traffic_quota.lua` parsed the pre-7.10 `Mmm/dd/yyyy` date layout against the
  pinned RouterOS iso `yyyy-MM-dd`, so the "month" key changed daily. It also
  reset `QUOTA_PREV_*` to 0 on rollover and then treated the whole interface
  counter as new-month traffic. ISO dates are parsed; PREV is baselined at the
  current counters on rollover.
- `backup_file_cleanup.lua` exposed `RetentionDays` but hardcoded `30d`, and
  matched `name~"backup-"` unanchored. Retention now drives the cutoff, and the
  match is `^backup-`.
- `ddns_update.lua` skipped DHCP/PPPoE WAN addresses (`!dynamic`), claimed PATCH
  while issuing PUT (which resets omitted Cloudflare fields), and fetched
  without `check-certificate`. It now prefers a dynamic address, PATCHes only
  `content`, and verifies TLS. `tg_send.lua` likewise enables
  `check-certificate=yes`.
- `vpn_health.lua` / `wireguard_watch.lua` treated WireGuard `last-handshake`
  incorrectly: any nonempty value was "up forever", and the watch compared
  elapsed handshake time to wall-clock time. Both now treat it as elapsed time
  against a stale threshold; never-handshaked peers count as stale.
- `mac_allowlist_dhcp.lua` compared MACs case-sensitively while README examples
  are lowercase and RouterOS leases are commonly uppercase. Both sides are
  lowercased when `:convert transform=lc` is available.
- `git_stale_branches.sh` crashed on a ref containing `|` (legal in Git) because
  fields were `|`-delimited. It now uses tabs, matching `git_recent_branches.sh`.
- `git_remote_doctor.py` printed shell `credential.helper` bodies verbatim,
  including `password=…` tokens, and recommended plaintext `store` on Linux. Shell
  helpers are redacted; the Linux hint prefers `libsecret`.
- `kubectl_pod_diag.sh` discarded kubectl get failures with `|| true`, counted
  them as findings, and exited 0. Failed queries now exit 1; missing `python3`
  is exit 2 like a missing kubectl.
- macOS alias table still advertised `find→fd` / `grep→rg` after those shadows
  were removed; the row matches the file and the suite. Linux now asserts the
  same shadows stay gone (the changelog already claimed it did).
- The `stay_fresh.sh` run lock actually excludes the LaunchAgent. It lived
  under `"${TMPDIR:-/tmp}"`, and the agent's plist sets only `PATH` — so an
  agent run resolved that to `/tmp` while a terminal run resolved it to the
  per-user `/var/folders/...` directory: two different lock directories, and
  the manual-vs-agent overlap the lock's own comment promises to prevent went
  unprevented. The lock now lives under
  `$HOME/Library/Application Support/stay_fresh`, identical in both contexts
  (`STAY_FRESH_LOCK_DIR` is the test seam). The suite plants a lock and
  asserts rejection from a *different* TMPDIR, which the previous code let
  straight through; the voided-`--only` docker tests also stop depending on
  docker being absent from PATH, which held in the CI container and nowhere
  with a `/usr/bin/docker`.

- `--no-sudo` no longer rewrites steps that were already off. Memory is opt-in,
  and `--only` / `--skip-*` have already taken others off the list, but
  preflight still tagged all three root-owned steps as skipped because
  `--no-sudo` was passed. A `--only versions --no-sudo` run then listed DNS and
  system caches as refused, and every `--no-sudo` run blamed the unused memory
  purge on the flag. The reason is recorded only for a step that was still going
  to run; the `--no-sudo` warning is silent when none were. The tester suite
  asserts both, and both fail against the previous file.

- `stay_fresh.sh --only` no longer reports success after preflight has taken
  every named step back off the list. `--only docker` on a machine without
  Docker, or `--only system-caches --no-sudo`, reached the summary having done
  nothing and exited 0. A fully voided selection now fails preflight with
  exit 2 and names the step and the reason; a partial one warns and runs what
  is left; `--dry-run` previews the stop as a warning, like every other
  preflight check. Auto-skipped steps are also booked once: the summary used
  to claim 16 skips for 15 steps and list Homebrew under two names.

  A missing `TMPDIR` is created rather than announced as a stale lock. An
  unwritable one says it could not take the lock, not that another run held
  it. `have_tty` opens `/dev/tty` instead of asking `access(2)`, which is
  true of the device node even when a launchd job has no controlling terminal.
  The sudo keep-alive detaches from the script's stdio and re-checks the
  parent every five seconds, so a captured `out="$(stay_fresh ...)"` no longer
  blocks on an orphaned `sleep`.

  The tester suite asserts the `--only` and `TMPDIR` contracts; the new step
  and unprivileged suites assert the keep-alive, the TTY-less cask skip, and
  both EACCES lock branches. The steps suite refuses to start if `/dev/tty`
  can be opened, so a `compose run` that forgot `-T` fails at the door rather
  than on the cask assertions. Several of those fail against the previous file.

- The `ssh_keys` exemption added to `linux/hardening_audit.sh` trusted the
  group *name* and never looked at its membership. The Fedora and RHEL
  convention is safe because that group is *empty*; add a user to it, or create
  it by hand on Debian and chmod the keys `0640`, and every member can read the
  host identity while the check that exists to catch exactly that printed
  `pass`. Membership is now read with `getent`, and the exemption fails closed:
  without positive evidence the group is empty, the strict rule applies.
- That commit also reworded the host-key failure hint to "must not be
  group-writable or world-accessible", which names bits a `0640 root:root` key
  does not set — the same defect being fixed in `ssh_client_doctor.sh` in the
  same change. The hint now distinguishes group read, a populated `ssh_keys`
  group, and world access, and says which one applies.

- `linux/hardening_audit.sh` graded a stock Fedora or RHEL host as FAIL and
  exited `1`. It required SSH host private keys to match `^[0-7]00$`, but those
  distros ship `/etc/ssh/ssh_host_*_key` as `0640 root:ssh_keys` on purpose —
  sshd drops privileges and reads them through that group. Group *read* is now
  accepted when the key's group is `ssh_keys`; group write and any world access
  stay a failure everywhere. No tester image installs `openssh-server`, so CI
  never reached this check.
- `linux/ssh_client_doctor.sh` failed `~/.ssh/config` at mode `755` with the
  hint "644 is accepted; group/other write is not" — naming a bit that `755`
  does not set. The check enumerated group/other digits of `0` or `4`, which
  also rejects `5` (`r-x`) and `1` (`--x`). OpenSSH objects to these files being
  writable, not readable, so it now tests the write bit the hint always claimed
  to be testing.

- `windows/wsl/wsl_manage.ps1 restore` verified nothing when the `.sha256`
  sidecar was missing. `Test-BackupHash` was called without `-RequireSidecar`,
  which returns success in that case, so a backup whose sidecar had been
  deleted — or any tar dropped into the directory by something else — imported
  while the run printed no error at all, and the "restore refused because
  backup integrity verification failed" message was unreachable in exactly the
  case it described. Restore now verifies by default; `-AllowUnverified`
  imports a pre-sidecar backup as a stated choice.
- `windows/git-bash/install_dotfiles.sh` followed a symlinked target. Where a
  dotfiles repository owns `~/.bashrc`, `cp` wrote *through* the link into that
  repository, and the backup taken first held the resolved content rather than
  the link, so nothing could put it back. It now replaces the link itself and
  leaves what it pointed at alone.
- `linux/install_aliases.sh` had the mirror-image bug: `mktemp` + `mv` replaced
  the symlink rather than following it, so the block was installed into a new
  regular file and the repository quietly stopped being what bash read. It now
  writes through to the linked file and preserves its mode.
- `linux/disk_cleanup.sh --no-sudo` was only consulted when the caller was not
  root, so `sudo disk_cleanup.sh --no-sudo` ran every root-owned step anyway.
  The flag asks to skip root-owned work; who is running it is a different
  question.
- `linux/sysctl_defaults.sh --backup-file` truncated its target before writing.
  Only an explicit path can collide, since the default name is timestamped, and
  a backup destination is not worth destroying a file for. It now refuses a
  non-empty target.
- Native Windows contracts now distinguish PowerShell Core's own startup cache
  and its exact parent-directory metadata from script writes. They also caught
  `winget_bootstrap.ps1 import -DryRun` launching `winget export`, which
  populated source caches despite the no-write promise; preview now parses and
  reports the requested package file without launching winget.
- The Kubernetes toolbox now keeps `gcloud` and
  `gke-gcloud-auth-plugin` available inside `bash -lc`; Debian login shells
  rebuild `PATH` and previously discarded the Cloud SDK path set by the image.
- `macos-initial-setup/launchd/stay_fresh_agent.sh install --dry-run` booted out
  the running agent, wrote the plist and bootstrapped it — the same defect
  `systemd/stay_fresh_timer.sh` had on Linux, and found only because the two
  are twins. `--dry-run` was parsed and then used solely to add `--dry-run` to
  the plist's own arguments; `--print-only` was the only no-write path, and it
  is a different flag with different output.
- `macos-initial-setup/brewfile.sh dump --dry-run` ran `brew bundle dump` and
  replaced `--file` regardless, the same way `packages.sh dump` did.
- A dry run now answers on a machine that could not do the real work, matching
  what `--help` has always done. `install_apps.sh`, `install_devtools.sh`,
  `stay_fresh.sh`, `macos_defaults.sh`, `brewfile.sh` and
  `launchd/stay_fresh_agent.sh` stopped at a preflight — not macOS, no
  Homebrew, no network — and exited 2 without printing the plan they exist to
  show. Each preflight now reports and continues under `--dry-run`, and still
  exits 2 on a real run. `install_apps.sh` also called `df -g`, a macOS
  spelling GNU df rejects, which only a preview off macOS could reach.

- `mikrotik/export_config.py --diff` exited `0` whether the live configuration
  matched the stored file or had drifted, so a scheduled
  `export_config.py --diff || alert` could never fire — the one mode that
  exists to report drift was unable to report it. It now follows
  `git diff --exit-code` and the exit ladder every check script in this
  repository already uses: `0` no drift, `1` drift. `test_export_config.py`
  asserted `rc == 0` on the changed case, which pinned the broken behaviour;
  it now asserts both halves, since exiting `1` always would satisfy the drift
  case alone.
- `run-tests.sh` reported `all selected suites passed` and wrote
  `{"overall":"pass"}` when *every* selected suite was skipped for a missing
  runner. A skip leaves the failure count alone, which is right for one suite
  out of several and wrong when nothing ran at all: CI consuming the JSON on a
  partial checkout saw a green build over zero executed tests. A run with no
  executed suite now reports `{"overall":"empty"}`, says so, and exits non-zero.
- `test-env/static/test_run_tests.sh` ran `--list` with its exit status
  discarded and checked for two of the eight suite names, so `--list` could
  have regressed to exit 3, or dropped six suites, and still passed. The
  happy-path `--summary-file` run's exit code was unchecked too.

- `linux/packages.sh dump --file PATH --dry-run` wrote the file. `--dry-run`
  was parsed and then never consulted on the `dump` path, so the one mode that
  promises to touch nothing replaced whatever was at `--file`. Found by the
  widened convention check below, not by a human reading the script.
- `test-env/static/check_conventions.sh` ran every script with a bare
  `--dry-run`. For the ones driven by a subcommand that is a usage error: they
  exited 3 having written nothing, which is indistinguishable from a pass. So
  the check reported the repository clean while
  `stay_fresh_timer.sh install --dry-run` wrote two unit files and started a
  timer. It now drives those scripts through their real entry points, treats
  exit 3 as a gap in its own table rather than a pass, and reports a dry run
  that ends non-zero — a preview should answer even where the real thing
  cannot run. Adding the missing entries immediately surfaced `gacp.sh`,
  `set_git_profile.sh` and the `packages.sh` bug above, none of which had ever
  been exercised.

- `linux/sysctl_defaults.sh --revert` chose its backup by globbing `TMPDIR`,
  which defaults to the world-writable `/tmp`, and fed every key it read
  straight to the kernel. Any local user could leave a
  `sysctl_defaults-backup-*.txt` for root to find and set a sysctl of their
  choosing — `kernel.core_pattern` to a command, for instance. A backup must
  now be owned by root or by the caller and writable by nobody else, and only
  keys this script actually manages are restored; anything else is reported
  and skipped.
- `linux/sysctl_defaults.sh` fell back to `sysctl -w` whenever the target file
  under `PROC_SYS` was not writable. `sysctl(8)` always addresses the running
  kernel, so the override that exists to make the apply path testable let a
  test run retune the host it ran on — and the backup written beside it
  recorded the fixture's values, leaving `--revert` unable to undo it. Under a
  `PROC_SYS` override the fallback is now refused rather than taken.
- `linux/disk_cleanup.sh --coredump-dir` and `linux/config_backup.sh --paths`
  guarded against operating on `/` with an exact string comparison, so `//`,
  `/.`, `/../` and `/var/..` all went through. For `disk_cleanup` that reaches
  a recursive `find -type f` whose every hit is deleted with sudo, and `--days
  0` skips the age filter: against an unpatched copy, `--coredump-dir //`
  enumerated 3,644 files across the root filesystem in 25 seconds and was
  still going. Both now compare the resolved path.
- `linux/systemd/stay_fresh_timer.sh install --dry-run` wrote both unit files
  and ran `systemctl --user enable --now`. `--dry-run` was parsed but consulted
  only when building `ExecStart`; the sole no-write guard tested `--print-only`.
  The suite paired the two flags, so `--print-only` short-circuited and the
  dry-run path was never exercised. It now previews and exits before any write,
  ahead of the systemd preflight so a preview still answers on a machine that
  could not run the real thing.

- `linux/packages.sh --file --force` treated `--force` as the path, the same
  class of bug `--tag --push` had in `k8s-toolbox/build.sh`: a missing value
  that starts with `--` was accepted. It uses `require_value` now, and
  `--file=PATH` works as well.

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
  VS Code workspace-storage prune, appeared nowhere. Both were added
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

### Removed

- Cursor is gone from the macOS package. `install_apps.sh` no longer ships the
  `cursor` cask, and `stay_fresh.sh` no longer touches it: the editor list its
  cache steps iterate (`VSCODE_FAMILY`) is now stock VS Code only — `Code` and
  `Code - Insiders`. The third-party forks that list carried alongside Cursor
  (VSCodium, Windsurf, Void, Trae, Positron) were dropped with it, from the
  `workspaceStorage` prune, the `CachedExtensionVSIXs` sweep and the
  Electron/Chromium cache roots. Caches for an editor the package does not
  install are not the package's to delete. Flag names and step numbering are
  unchanged, so no invocation breaks; a machine with a fork installed simply
  keeps its caches now.
- `.mailmap` collapses the alias identities in `git log` onto
  `Serhii Zolotov <zolotov.98@gmail.com>`. Committed history is untouched;
  `git shortlog -sne` and `git log` read through the mapping, so the identity
  is normalised without a rewrite that would invalidate every clone.

### Changed

- `.claude/skills/` is local-only. The directory is gitignored and no longer
  published on GitHub; `CONTRIBUTING.md` is the public reference. Package
  READMEs that pointed at a skill now point at that file instead.

- macOS scheduled maintenance now defaults to a conservative `safe` profile:
  protected per-app caches, provably stale workspace storage and version
  reporting. `stay_fresh_agent.sh install --profile full` retains the previous
  broad behavior. Scheduled runs pass `--fail-on-warn`, so partial failures are
  visible in launchd's last exit status.
- `gem cleanup` is no longer presented or executed as cache cleanup. Old
  installed gem versions are kept unless `--cleanup-old-gems` is explicit.

- RouterOS CHR compatibility was bumped from 7.24 to 7.24.1 after the full Docker integration suite passed.
- RouterOS CHR compatibility was bumped from 7.23.3 to 7.24 after the full Docker integration suite passed.
- `linux/disk_cleanup.sh --days 0 --include-journal` now says that it removes
  the entire journal, including the entries describing whatever filled the disk.
  The combination stays available; it just is not a surprise any more.
- `linux/sysctl_defaults.sh --apply --only` now warns that the drop-in is
  rewritten with just the named groups, so any other group already in the file
  is dropped and reverts at the next boot rather than immediately.
- `linux/hardening_audit.sh` grades SSH host private key modes (`600`-style),
  AppArmor/SELinux *enforcing* rather than "LSM present", and a stale or
  missing unattended-upgrades / dnf-automatic stamp when automatic updates
  are configured.
- `linux/disk_cleanup.sh --include-coredumps` age-filters
  `/var/lib/systemd/coredump` and `/var/crash`. `--coredump-dir` is the test
  seam; `/` is refused. Off by default, like trash and docker prune.
- `linux/system_doctor.sh` now reports timezone and NTP synchronisation,
  pending upgrades from the local package index (no network), error-level
  journal lines since boot, login sessions, OOM kills this boot, processes
  still running old libraries after an upgrade, kernel taint, coredump file
  counts, and `docker`/`podman system df` when the daemon answers. Volumes
  are listed, never pruned.
- `linux/net_doctor.sh` reports the default IPv6 route as information; a
  v4-only host is not a warning. It also says whether the local hostname
  resolves — the usual cause of a multi-second `sudo` delay.
- `linux/schedule_report.sh` reports lingering for the current user, because
  a user timer that is installed but never fires is almost always linger-off.
- `linux/tls_expiry.sh` answers missing `--file`/`--host` as usage (exit 3)
  before the openssl preflight, so a Fedora image without openssl still
  fails the flag contract rather than looking like a missing binary. Quoted
  `--file` globs expand, so a Let's Encrypt live directory is one argument.
- `linux/config_backup.sh --list` prints the newest archive (or a named
  file) without writing.
- Add a safe Kali VM cloud-init configuration for first boot with
  key-only SSH, package/network timeouts, baseline networking commands, Kali
  red/blue team metapackages, UFW prepared but disabled, completion logging,
  and fresh OrbStack Kali VM validation; document that OrbStack's current stock
  Kali image does not yet include cloud-init.
- Document Kali red/blue lab sizing, installed roles, standard cloud-init use,
  the tested OrbStack NoCloud procedure, monitoring, verification, recovery,
  and the boundary between Docker contract tests and full VM validation.
- Refresh the Arch Linux Docker test image pin and install the test suite's
  explicit YAML and diff dependencies on every Linux fixture; keep Fedora's
  package capture compatible with dnf5's explicit record-separator behavior,
  make the systemd unit validator selectable for emulated test images, and run
  Debian, Fedora, and Arch as separate pull-request CI checks.
- macOS `stay_fresh.sh` now requires explicit authorization for non-interactive
  mutation, prevents overlapping runs, keeps Xcode Archives unless an age-based
  prune is requested, and protects running or unidentifiable application caches
  by default. `purge` is opt-in, deletion failures reach the WARN summary, and
  Homebrew upgrades formulae and casks in distinct passes. Its LaunchAgent now
  supplies a deterministic PATH, performs formula-only unattended upgrades,
  refuses to kill an active run, and retains ten dated execution logs.
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
