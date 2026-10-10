# Changelog

All notable changes to this repository are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
releases follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Each
release is tagged `v<version>` on the commit that adds its section here; see
[Cutting a release](changelog.d/README.md#cutting-a-release).

The dated sections at the bottom predate versioning. They are reconstructed
from the merge commits in `git log` and grouped by the day each pull request
landed on `master`; they are history, not releases. The first version is cut
from `[Unreleased]`, and from then on every entry here belongs to a version.

New entries are not added to `[Unreleased]` by hand. Each change ships one
file under [`changelog.d/`](changelog.d/README.md), and
`changelog.d/changelog.sh preview` prints the section with those fragments
pasted in ahead of what it already holds; `changelog.d/changelog.sh release`
moves both under a version heading. The entries below were written before
that directory existed and stay here until the first release moves them.

## [Unreleased]

## [0.1.0] - 2026-10-10

### Added

- A scheduled `stay_fresh` run defers entirely on battery, and runs only the
  read-only reports when somebody has used the keyboard in the last five
  minutes. A full sweep is minutes of `du` and `rm` plus a `brew upgrade`, and
  neither a battery nor a working afternoon should pay for it unasked. The
  decision is recorded in the scheduled-run stamp and shown by `status`, so a
  deferral is never silent; `--ignore-power` skips both checks, and neither
  applies to `run-now`.

- Branch names follow one convention, `<type>/<slug>` with the type one of
  `feat`, `fix`, `docs`, `ci`, `test`, `perf`, `refactor`, `deps` or
  `release`, written down in `CONTRIBUTING.md` and enforced by the new `Branch
  name` workflow through `test-env/static/check_branch_name.sh`. `chore/` is
  gone: the RouterOS version workflow now opens `deps/routeros-<version>`
  titled `deps(mikrotik): ...`, the Release workflow opens
  `release/<version>` titled `release: <version>`, and Dependabot's commits
  use the `deps` prefix. A pull request title opening with a `chore` type is
  refused, because a squash merge makes it the commit subject on `master`.
  The `pull_request` target filters in `ci.yml`, `chr.yml` and `security.yml`
  now list every type. Before, a pull request stacked onto a `docs/`,
  `test/`, `perf/` or `refactor/` branch ran no checks at all and merged
  green.

- CI builds its `Test / <suite>` matrix from `run-tests.sh --list`, which now
  prints each suite's package directory as a second column. Adding a suite
  used to take four hand edits to the workflow - a job output, a filter line,
  a matrix entry and a summary row - and the dotfiles suite arrived with the
  summary row missing. The aggregator's table was already the one place to
  add a suite for everything local; it is now the one place for CI too, and
  the contract test checks that every listed package directory exists.

- `git/clone-repos.sh` clones every repository listed in a text file into
  one parent directory, one URL per line with an optional destination, and
  `repos.txt.example` shows the format. A checkout that is already there is
  skipped, an occupied path is reported and left alone, and one bad line
  never stops the rest; the exit code says whether everything landed. It
  follows the package's contract: `--help` before any check, `3` on a bad
  flag, both `--dir DIR` and `--dir=DIR`, and a `--dry-run` that prints the
  clones it would run and writes nothing. `gclone` is its alias in both
  alias files.

- A documentation site, built with MkDocs and the Material theme from `docs/`
  and `mkdocs.yml`. It has a quick start, the report, preview and apply
  philosophy, one page per platform, a table of the main scripts, testing
  and contributing guides, and the roadmap and changelog rendered from the
  root files at build time so they cannot drift. The build tools are pinned
  in `docs/requirements.in` and hash-locked with their dependencies in
  `docs/requirements.txt`, and `README.md` and `CONTRIBUTING.md` show how
  to preview it locally. The `docs.yml` workflow builds it on pull requests
  and deploys it with wrangler as one Cloudflare Worker (`worker/`): a push to
  `master` updates the stage preview at <https://stage.ops.szolotov.com>, and a
  release, or a manual run with a `v*` tag, deploys <https://ops.szolotov.com>,
  rolling back if its smoke test fails.

- The dotfiles suite parses its TOML, YAML, JSON and Python configs in one
  Python run instead of one interpreter launch per file, which was most of
  the suite's wall clock. Per-file verdicts and the skip-when-no-parser
  behaviour are unchanged.

- `git/git_ignore_doctor.py` explains why a path is ignored, or why it
  stubbornly is not. `git check-ignore -v` names the rule that matched and
  nothing about why the rule you wrote is not it, so the script asks git twice
  — once with the index, once with `--no-index` — and reads the difference: a
  file committed before its rule existed is not ignored at all, the rule is
  inert until the file leaves the index, and `check-ignore` reports that as no
  match rather than as the trap it is. Run with no argument it sweeps the
  repository for every tracked file an ignore rule claims. It also names a
  negation under an excluded directory, which git can never reach, and prints
  the whole ladder that re-includes the file — `build/*`, `!build/keep/`,
  `!build/keep/note.txt` — because `build/*` on its own leaves the file exactly
  as ignored as it was. Read-only, like the three doctors beside it.

- `k8s-toolbox/gke_cluster_doctor.sh` reports a GKE cluster's release
  channel, control-plane vs node-pool skew, Workload Identity, and
  private-cluster flags. It prints the `gcloud` command that would fix
  each finding and never mutates the cluster. `--list-checks` and `--help`
  work before `gcloud` is required.

- `install_apps.sh` takes `--profile`, a named subset of the two catalogues for
  the common case of setting a machine up for a role rather than naming forty
  casks by hand. `core` is a day-one machine that can work, `platform` adds the
  Kubernetes, cloud and IaC tools, and `full` is the unfiltered catalogue and
  still the default. `--list-profiles` prints the names and what each is for.
  Both answer before the macOS preflight, as `--list-casks` and `--list-tools`
  do, so a runbook can be written from a Linux box. A profile fills `--only` and
  `--only-formulae` only when they are unset: an explicit selector is an
  instruction and wins. A profile naming an id the catalogue does not have exits
  3 rather than quietly installing less than it says.
- The catalogue gains Secretive and Ghostty as casks, and `glab`, `gitleaks`,
  `syft`, `kubeconform`, `yamllint`, `rclone`, `direnv`, `actionlint` and
  `ansible` as formulae.

- `install_apps.sh` grew `--list-casks` and `--list-formulae`, the same
  shape as `install_devtools.sh --list-tools`, both answering before preflight
  so they work on a machine the script refuses to run on. The catalogue adds
  Obsidian and Stats, plus `gh`, `sops`, `age`, `cloud-sql-proxy`, `fzf`,
  `ripgrep`, `fd`, `k6`, `shellcheck` and `hadolint`. Vault and Packer are
  deliberately absent: HashiCorp relicensed them under the BUSL, homebrew-core
  dropped them, and the working spelling is now `hashicorp/tap/vault` — a tap
  this script does not add, so listing them would have been a name nobody can
  install.

- Map installed third-party apps to their exact bundle-ID and sandbox cache
  directories, and include named Teams WebView cache leaves. Preview reports
  individual paths and sizes; running apps and failed activity checks keep their
  data. Databases, recordings, models and unmapped containers are preserved.

- Add repeatable `--prune-jetbrains-version NAME` to the macOS app-cache step.
  It removes only explicitly selected older versions from the default JetBrains
  settings/plugin, cache/Local History and log roots. Previews show exact paths
  and sizes. Newest/unselected versions, unsafe inventories and active or
  uninspectable IDEs are preserved; ordinary and deep cleanup keep version data.

- `linux/status.sh` prints a one-screen verdict for a Linux machine
  (os, disk, packages, reboot, timer, git). `--list-sections` and `--only`
  work before any preflight, including off Linux. It writes nothing.
  `install_aliases.sh` exposes it as `linux-status`.

- `./run-tests.sh lint` runs, locally, what CI's `Lint` job runs: `bash -n`,
  ShellCheck (both passes), actionlint, Hadolint, PSScriptAnalyzer, yamllint
  and markdownlint-cli2, at the versions pinned in
  `.github/ci-tool-checksums.env` and `ci.yml`. Those seven had no local entry
  point at all, which is how a changelog fragment reached a pull request with a
  markdownlint violation while the linter sat installed on the same machine. A
  missing or differently-versioned tool is a named skip, a run in which no
  linter ran fails, every zero-file case fails, and nothing is fetched unless
  `LINT_FETCH=1` — the three release binaries are then verified against the
  recorded digests. The `Lint` job now calls the suite instead of carrying its
  own copy of each invocation, and markdownlint-cli2 is pinned by version
  (`MARKDOWNLINT_VERSION`) rather than only by the action SHA that wrapped it.

- `macos-initial-setup/stay_fresh.sh` adds `--prune-system-logs` to the
  diagnostics step for selected rotated system, installer and Wi-Fi log
  archives older than 30 days. The standalone
  `macos-initial-setup/lib/system_logs.py` validates each file before removal;
  previews write nothing, and current logs, recent archives, unrelated files
  and subdirectories are preserved. Deletion requires sudo and remains
  separate from automatic cache cleanup.

- `macos-initial-setup/status.sh` prints a one-screen verdict for a Mac
  (os, disk, brew, git, agent, security). `--list-sections` and `--only`
  work before any preflight, including off macOS. It writes nothing.

- `macos-initial-setup/stay_fresh.sh` extends its disk report to app group
  containers, local model stores, npm and pnpm data, and readable system cache
  and temporary-data roots. Reported sizes are not promised reclaimable space.
- Optional deep cleanup classifies old default npx cache entries with
  `macos-initial-setup/lib/npx_cache.py`, preserving recent entries, active
  processes, ambiguous configuration and unsafe paths. Downloaded models,
  virtual machines and application databases remain untouched.

- `test-env/static/check_pin_age.sh` fails CI when a Dependabot-unwatched
  pin file (`k8s-toolbox/versions.env`, `.github/ci-tool-checksums.env`,
  `mikrotik/tests/routeros-version.env`) has no `# last-reviewed:
  YYYY-MM-DD` stamp, or that date is older than 90 days.

- Releases are tagged. `.github/workflows/release.yml` cuts one in two steps:
  run by hand with a version, it runs `changelog.sh release` on a
  `chore/release-<version>` branch and opens that as a pull request; merging
  it tags the merge commit `v<version>` and publishes a GitHub Release whose
  notes are the version's section of this file. Only the push that adds a
  version's heading is tagged, so a later edit here never moves a release, and
  notes too long for a release description are linked and attached instead of
  failing the publish. Until now the repository had no tag at all, and
  `changelog.d/README.md` described tagging as a command to remember to type.
- `changelog.sh latest` prints the newest released version and `changelog.sh
  notes VERSION` prints that version's section, so the workflow reads
  `CHANGELOG.md` through the tested script instead of parsing it itself.

- `ROADMAP.md` is now in the tree. It existed for months on an unmerged
  branch, which is how most of it came true without anyone crossing it off and
  how the rest went stale: it was still calling #33 the next merge five merges
  later. Every claim in it has been re-checked against the tree, so what is
  left reads as the two things actually outstanding — the sixteen RouterOS
  scripts that 7.24 refuses to execute, and the first tag — rather than as a
  wish list. `README.md` points at it, because a plan nobody can find is a
  plan nobody reads.

- `mikrotik/features/security_check.lua` is a read-only hardening audit of a
  RouterOS box — the counterpart of `linux/hardening_audit.sh` and
  `macos-initial-setup/hardening_audit.sh`. It grades services listening
  on all addresses, default identity/admin, discovery and MAC-server
  exposure, DNS recursion, SNMP, UPnP, SOCKS, bandwidth-server, and an
  empty IPv6 filter, then Telegrams the scan with the command that would
  close each finding. It never changes router config. No underscored
  `:global` names, so it runs on RouterOS 7.24 where most of the folder
  cannot.

- Clear idle Cursor's downloaded extension package cache while preserving installed
  extensions and settings; keep packages when activity cannot be established.

- `macos-initial-setup/stay_fresh.sh` adds `--full`, combining age-limited macOS
  cleanup with Homebrew update, formula and greedy cask upgrades, cleanup and
  autoremove, supported developer-tool refreshes, and update reports. The guide
  explains Homebrew retention differences and when cask upgrades are skipped.

- `stay_fresh.sh` classifies idle Claude renderer caches through
  `large_storage.py`. VM bundles, sessions, Service Worker data, blob storage,
  GeForce NOW data, JetBrains Local History and downloaded models remain kept,
  including during `--deep-clean`. Helper executables count as app activity;
  a failed process check keeps caches even with `--force-active-app-caches`.

- `stay_fresh.sh` draws a live line while a step runs: the step, its position
  in the plan and its elapsed time, rewriting in place. Homebrew and Xcode take
  minutes and say nothing while they do, and a static `==> Homebrew` gave no way
  to tell a slow step from a hung one.
- It is written to `/dev/tty`, never to stdout, so the log file, a pipe, this
  repository's test suites and CI see exactly the bytes they saw before. Piping
  the step through a filter would have kept the line clear of the step's own
  output and was not available: a piped step runs in a subshell, and the freed
  bytes and warning counts set in there would never reach the caller. The line
  waits a second before drawing, by which time a step has printed its opening
  lines and gone quiet — and a step that finishes inside that second never
  draws at all, which is most of them.
- `--no-progress`, or `STAY_FRESH_PROGRESS=0`, turns it off.

- `macos-initial-setup/stay_fresh.sh` extends deep cleanup with installed
  messenger profile and partition caches, including sandboxed Slack. Exact
  renderer-cache leaves are selected; conversation stores, attachments, login
  state and whole containers remain intact. Active or unknown messenger
  activity preserves these caches even when the force option is supplied.

- `macos-initial-setup/stay_fresh.sh` adds messenger-only cleanup with optional
  app selection and per-app preview totals. Installed-app activity is rechecked
  after sizing before each deletion. Run-lock retirement is reserved before
  acquisition, including recovery from failed metadata publication.
- `macos-initial-setup/launchd/stay_fresh_agent.sh` restores the prior plist and
  loaded job when install/uninstall is interrupted by INT, TERM or HUP before
  commit, and retains recovery material if rollback fails.

- `stay_fresh.sh` reaches four cache roots it used to walk past: Spotify's
  `PersistentCache`, which is routinely several gigabytes and sits outside
  `~/Library/Caches` where the user-cache step cannot see it; `bun`'s package
  cache, through `bun pm cache rm` where that exists and the directory
  otherwise; `~/.minikube/cache`, whose ISOs and preload tarballs are hundreds
  of megabytes per Kubernetes version and are re-downloaded on demand; and
  `~/.gradle/wrapper/dists`, a whole Gradle distribution per version any
  project's wrapper ever asked for. Spotify is covered by the running-app
  guard like every other application, minikube's `machines/`, `profiles/` and
  `certs/` are never touched, and the Gradle wrapper distributions join the
  other build caches behind `--prune-build-caches`.

- `macos-initial-setup/stay_fresh.sh` adds `--old-only` for age-limited user logs,
  guarded rotated system logs and old idle npx entries, with storage and snapshot
  reports. It preserves bulk caches, Trash and installed software even alongside
  `--deep-clean`, rejects broader cleanup options, and names user-log candidates
  in verbose output. The README explains retention rules and System Data scope.

- `macos-initial-setup/stay_fresh.sh` accepts `--user-log-days` and
  `--npx-cache-days`, validates their bounds before cleanup, and shows the
  effective retention in its plan. Full maintenance retains its Homebrew cycle;
  changing retention does not enable skipped steps or alter system-log policy.

- `stay_fresh.sh --trend` reads the runs already recorded and answers what a
  single run cannot: whether free space is keeping up (it compares the space
  left after each run, not just what each run freed), which steps do the work,
  and which are taking steadily longer — the shape of a cache growing out of
  control, visible long before it is visible as a full disk. Read-only. Each
  run now also records one row per step in `steps.tsv` beside `history.tsv`,
  and the history row carries the free space left after the run.

- `windows/setup/status.ps1` prints a one-screen verdict for a Windows
  workstation (os, disk, winget, wsl, reboot, git). `-ListSections` and
  `-Only` answer before the Windows preflight, including on Linux pwsh.
  It writes nothing.

- `zsh_aliases.zsh` puts `$KREW_ROOT/bin` on `PATH` when the directory exists,
  so kubectl can find the plugins krew installed and krew stops telling you to
  add the line yourself. Guarded both ways, like the `GOPATH` entry beside it:
  nothing changes on a machine without krew, and re-sourcing the file does not
  stack copies.

- `stay_fresh.sh` step `downloads`: top-level entries in `~/Downloads`
  untouched for 90 days are counted, totalled and the largest named. Nothing
  is removed unless `--prune-downloads-days N` is explicit, a dry run lists
  what would go, and hidden entries are never touched. Installers and
  archives land there and nothing on the machine ever looks at them again.
- `stay_fresh.sh` step `launch-agents`: plists under `~/Library/LaunchAgents`,
  `/Library/LaunchAgents` and `/Library/LaunchDaemons` whose program (the
  `Program` key, the first `ProgramArguments` entry, or the script an
  interpreter is handed) no longer exists are named. Every uninstalled tool
  leaves one, and launchd retries it at every login. `--prune-orphan-agents`
  unloads and removes the user-level ones; system-level ones are only ever
  named with the `sudo` command. Both new steps are part of `--reports` and
  of the agent's `safe` profile, as reports.
- `stay_fresh.sh --notify-when always|warn|fail` (env
  `STAY_FRESH_NOTIFY_WHEN`): a banner every morning gets swiped away unread;
  `warn` keeps the channel for the runs that need reading. A withheld
  notification is said on the terminal. `stay_fresh_agent.sh install
  --notify-when` passes it through, validated by `stay_fresh.sh` itself.
- `stay_fresh.sh --dry-run` ends with a `would free` line: the sizes of
  everything the deletions would have removed, added up across steps, so a
  preview answers the question it is run for.
- The Homebrew step names a `brew services` entry in `error` state (a
  daemon launchd gave up restarting, which nothing else in the run would
  mention) and carries the count into the verdict, and names an Intel
  Homebrew still installed at `/usr/local/Homebrew` on Apple silicon.
- `zsh_aliases.zsh` completes `--notify-when` values and the new flags.

- `stay_fresh.sh` step `user-logs`: files under `~/Library/Logs` older than
  30 days are removed. Every app, daemon and installer writes there and
  nothing prunes it. Directories stay, because an app whose log directory
  vanished may not recreate it; `DiagnosticReports` (the diagnostics step's)
  and the script's own `stay_fresh` directory are left alone. Part of
  `--quick`; `--skip-user-logs` to keep them.
- `stay_fresh.sh --reports`: the read-only subset (`versions`, `os-updates`,
  `snapshots`, `disk-report`) as one flag, for a look at the machine that
  changes nothing. It refuses `--thin-snapshots`, because then it would.
- `stay_fresh.sh --prune-build-caches` clears `~/.gradle/caches` and
  `~/.m2/repository` during the dev-cache step. Without the flag they are
  named and kept: they are the largest thing under `HOME` on a JVM
  workstation and the slowest to get back, since the next build downloads
  every dependency again.
- `stay_fresh.sh --notify slack` posts the verdict to a Slack incoming
  webhook (`STAY_FRESH_SLACK_WEBHOOK`, or the `stay_fresh-slack` Keychain
  item). The URL is the credential, so like the Telegram token it goes to
  `curl` as a config file on stdin and is scrubbed from any error.
  `--notify` also takes a comma-separated list (`macos,slack`); `both`
  still means `macos,telegram`. `stay_fresh_agent.sh install --notify`
  validates the same list.
- `stay_fresh_agent.sh status` says when the job has stopped running: the
  last run's timestamp against the plist's schedule (weekly with a
  `Weekday`, daily otherwise), a warning and exit `1` past twice the
  interval. launchd still reports such a job as loaded and the last verdict
  still reads OK, which is how a Mac asleep every Monday at 10:30 goes
  unmaintained for months.
- `zsh_aliases.zsh` completes `stay_fresh.sh` (and `stay-fresh`,
  `stayfresh`): the flags from the script's `--help`, the step ids after
  `--only` and the channels after `--notify`, comma-separated. Both lists
  are read from the script, so a new flag or step is completable the moment
  it exists.

- `stay_fresh.sh --step-timeout N` (default 1800, `0` disables, env
  `STAY_FRESH_STEP_TIMEOUT`): every command a step runs is stopped after N
  seconds and the step counts as warned. `brew update`, `softwareupdate
  --list`, `gcloud components update`, `helm plugin update` and
  `kubectl krew update` all talk to the network with no bound of their own;
  one that hung stalled the scheduled agent, and the run lock then turned
  every later run away with "another run is active" until somebody killed
  the process, with no verdict and no notification to say so. macOS ships no
  `timeout`, so the limit is perl's `alarm`, which every macOS has. Without
  a terminal the command runs in its own process group so the children brew
  and gcloud fork stop with it; at a terminal it stays in the shell's group,
  because a command that asks a question there must be able to read the
  answer, and `run_cmd_tty` (cask upgrades, sudo prompts) is never limited.
- `stay_fresh_agent.sh status` prints the last run's verdict: the headline
  and detail line from `last-run.json`, which was written for exactly that
  reader and had none.
- The versions report names the tools the run maintains and did not list:
  `kubectl` and its krew, `terraform` (with `CHECKPOINT_DISABLE=1`, so a
  version print does not phone home or write the checkpoint cache) and
  `docker`.

- `stay_fresh.sh` refreshes the kubectl plugins installed through krew:
  `kubectl krew update` for the index, then `kubectl krew upgrade` per
  plugin. `install_apps.sh` puts krew on the machine as a Homebrew formula,
  but the plugins it installs are not Homebrew's, and nothing in the run
  moved them, the same gap the Helm plugin step already closed for Helm.
  krew prints a header to a terminal and bare names to a pipe; the parser
  takes both. `--skip-krew`, folded into `--skip-devtools` with the other
  refresh steps, and the `krew` id for `--only`. The Docker steps suite runs
  it against both output shapes, counts a failed upgrade as a warning, and
  checks `--skip-devtools` covers it and a kubectl without krew is a clean
  step.

- `stay_fresh.sh` ends every real run with a verdict it can act on: a
  headline (`stay_fresh OK: freed 1.2G in 4m10s`) and a detail line with the
  step counts, the packages Homebrew upgraded, the casks still outdated, the
  OS and App Store updates pending, the local snapshots found, and the
  uptime. The same two lines go to a Notification Center banner or a Telegram
  message (`--notify none|macos|telegram|both|auto`; `auto` posts a banner
  when no terminal is attached, which is the scheduled case), into
  `~/Library/Logs/stay_fresh/history.tsv` (one row per run; `--history`
  prints the last ten), and into `last-run.json` next to it. The Telegram
  token comes from the environment or the login Keychain and is handed to
  `curl` as a config file on stdin, never as an argument. Two new steps:
  `snapshots` lists local Time Machine snapshots, the usual reason `df` does
  not move after a cleanup, and deletes them only with `--thin-snapshots`
  (sudo; demoted to listing under `--no-sudo`); `disk-report`, opt-in through
  `--disk-report`, prints the largest entries under `~/Library/Caches`,
  `Application Support`, `Containers`, `Developer`, `Logs`, `~/.cache` and
  `~/Downloads`, and the size of device backups, read-only. `--quick` is the
  user-level cleanup as one flag (user, app and AI caches, workspace storage,
  Trash, dev-tool caches: no sudo, no Homebrew, no reports). The trash step
  also empties `/Volumes/*/.Trashes/<uid>`, the per-volume Trash that only
  Finder ever drained. `launchd/stay_fresh_agent.sh install --notify MODE`
  stores the mode in the plist and passes it through. The steps suite covers
  each of these with faked `osascript`, `curl`, `security`, `tmutil` and
  `sysctl`, and the contract suite the agent's plist and option rejection.

- `backup_update_check.lua` takes its verdict from RouterOS's `status` line,
  polled until it settles, instead of a fixed 15-second wait and an
  `installed != latest` comparison. Measured on a 7.24.2 CHR: issuing the
  check clears `latest-version` at once, a good check refills it in about a
  second, and a failed check leaves it empty with an `ERROR:` line in
  `status`. The old comparison sent that empty field down the "not required"
  branch, so a router whose DNS or outbound HTTPS broke reported "update is
  not required" with a blank Latest every morning, which is how a fleet
  quietly stops being checked. A failed check is now its own message,
  "update check FAILED",
  with the reason, the `status` line, the update mode, the NTP client state
  and the DNS servers, and the command to run by hand; it takes no backup and
  prunes nothing. Every message carries the `status` line and the router's
  clock. The "update is required" message adds the license level, the
  installed packages with their versions (a disabled one marked), the board's
  health readings where it has any, a changelog link, and a reboot-impact
  section: interfaces running, DHCP leases bound, PPP sessions active,
  WireGuard peers. Two risk lines appear in any message only when non-zero:
  `supout` crash dumps on the router, and `critical` log entries with the
  last one's text. Text the script did not write itself is HTML-escaped,
  since Telegram rejects the whole message on one unbalanced `<`. The storage
  line shows free space beside the size of the installed packages and warns
  under `MinFreeStorageMiB` (16 by default, the floor `stay_fresh.lua`
  shares; 0 disables it, which a 16 MB flash router needs), and a non-zero
  `bad-blocks` figure is reported as a warning beside the number.

- Three CHR tests around the update check. One triggers a real check and
  records how `status` and `latest-version` move, then dumps every field the
  update scripts read into the CI log: on 7.24.2, `check-for-updates once`
  returns in 0.1s, `status` reads "finding out latest version..." while the
  check runs and settles in about two seconds, `/system routerboard` does not
  exist on the CHR, and `/system health` has no readings there. One forces a
  failed check by pointing the update hosts at the router itself and records
  what this release does: `status` becomes "ERROR: IPv4: server is not
  responding / IPv6: no internet connection" and `latest-version` is left
  empty, not stale, which corrects a claim the update scripts' comments had
  made. Two run `backup_update_check.lua` end to end
  through a Telegram stub whose `:global` has no underscore, the first update
  script the suite executes on the CHR rather than xfails: on the stable
  channel for the heartbeat, and with the channel patched to `development`,
  where a newer build is usually offered, for the backup pair and the full
  message.

- `dotfiles/`, a new package: configuration for the tools already installed
  on a DevOps workstation, one file per tool with every setting commented, and
  `install_dotfiles.sh` to link them into a home directory. The repository
  installed the tools — `install_apps.sh`, `install_devtools.sh`, the
  Brewfile — and then left every one of them on its defaults, which for
  `git` means no `rerere`, no `push.autoSetupRemote` and a merge conflict
  style from 2005; for `ssh` and `gpg` means the weak defaults their
  hardening guides exist to replace; and for `k9s`, `starship`, `bat`,
  `ripgrep` and the terminals means a first hour on every new machine spent
  re-deriving the same twenty lines. The settings were checked against each
  tool's own documentation and the README says where. The installer links one
  file at a time so runtime state stays out of the repository, copies the
  four files their tools rewrite in full, refuses to overwrite anything
  without `--force` (which keeps a `.backup`), reports `MATCH` / `DRIFT` /
  `MISSING` / `CONFLICT` under `--status`, and removes only what it made.
  A ninth suite, `./run-tests.sh dotfiles`, runs the installer against a
  scratch home and parses every tracked config with the tool or format
  parser it belongs to. Nothing here carries a credential, and the suite
  greps for the usual token shapes to keep it that way.

- `stay_fresh.sh` ends with a read-only report of pending macOS and App Store
  updates: `softwareupdate --list`, and `mas outdated` where `mas` is
  installed. The script upgraded everything Homebrew manages and said nothing
  about the operating system underneath, which is the one update that matters
  most and the one that sits unnoticed in System Settings. It names what is
  pending and the command that installs it, and never installs anything,
  because a macOS update can reboot the machine and that is the operator's
  decision. Pending updates are information, not a warning, so the scheduled
  `--fail-on-warn` agent does not go red every morning between patch days; a
  query that fails - offline, not signed in to the App Store - is reported
  and does not count against the step either, for the same reason.
  Not probed under `--dry-run`, where the catalogue scan would break the
  promise to answer quickly and touch nothing. `--skip-os-updates` and the
  `os-updates` id for `--only`.

- `stay_fresh.sh` dev-caches also runs `uv cache clean` and clears
  `~/.kube/cache`. uv's cache is separate from pip's and routinely larger; the
  kubectl cache holds per-cluster API discovery for every cluster a kubeconfig
  has ever pointed at, including the ones that no longer exist, and kubectl
  rebuilds it on the next call. `~/.kube/config` is not under that directory
  and is not touched.

- `stay_fresh.sh` routes pip's output to the log unless `--verbose`, like
  every other command. It used to tee to the terminal regardless, so a quiet
  run showed one stray "WARNING: No matching packages" line from pip and
  nothing from anything else.

- `stay_fresh.sh --yes` passes `--yes` to `brew upgrade` only after
  `brew upgrade --help` documents it. Current Homebrew asks for confirmation
  before downloading, and `--yes` is what keeps the LaunchAgent from stalling
  on that prompt; an older Homebrew rejects the flag as an invalid option,
  which turned every upgrade into a warning. The script now probes once and
  says so when it runs without the flag.

- `.gitignore` ignores every dot-directory at the repository root and
  re-admits `.github/`, the one that is tracked. The local agent skills
  directory used to be ignored by name; the rule now covers it and every
  other coding agent's local state without naming any, and `CONTRIBUTING.md`
  and the README are true again when they say that directory is gitignored.
  A future tracked dot-directory needs its own negation line, and the comment
  in `.gitignore` says so.

- The Docker steps suite covers the four: the report with pending, current,
  and unreachable update servers, the dry run scanning nothing, the two new
  cache targets, pip's notice staying out of a quiet run, and the brew flag
  probe against a Homebrew with and without `--yes`. The seventeenth step is
  exercised for real like the sixteen before it.

- `stay_fresh.lua`: the RouterOS counterpart of the macOS and Linux
  `stay_fresh.sh`. `update_check.lua` and `backup_update_check.lua` say a
  release is waiting and leave the install to whoever reads the message, which
  on a fleet of home and branch routers is the step that waits for a weekend
  that never comes. This one installs it: when RouterOS's own verdict is that a
  newer release is offered on the channel, it writes the
  `backup-IDENTITY-DATE-VERSION-pre-upgrade` pair, prunes the older
  generations, announces what it is about to do and runs
  `/system package update install`, which downloads and reboots; on the run
  after, when the RouterBOARD firmware is behind, it upgrades that and reboots
  once more, one action per run in the order MikroTik documents. What keeps it
  from rebooting a router it should not: a maintenance window in local hours
  (03:00 to 05:59 by default, outside it the run reports "deferred" and changes
  nothing), the `status` verdict rather than `installed != latest` so a channel
  switch never installs an older release, a check that errors or times out
  installing nothing and saying so, the install refused when the pre-upgrade
  pair was not written, a free-storage floor checked before the download, and
  `StayFreshDryRun`, which does the check and the report and nothing else and
  is the way to run the first tick. Every knob is a `:global` set at boot so a
  fleet is tuned from one startup script. Every run ends in a message,
  including a one-line "fresh, nothing to install" heartbeat, because a script
  that reboots routers should never be silent about having run. No `:global`
  here carries an underscore, so it runs on RouterOS 7.24 where
  `update_check.lua` does not; it looks for `tg_send_new` first and falls back
  to `tg_send` on the releases that run it, encoding line breaks the way that
  helper's form body needs. With no helper resolved it checks and logs and
  refuses to install or reboot, because a router that reboots without saying
  so is the failure it exists to avoid (`StayFreshRequireNotify false` for a
  router with no Telegram at all). The firmware step compares versions
  numerically, so firmware newer than the bundled one is never flashed down.
  `print_schedulers.sh --update-script` picks which of the three update
  scripts to schedule and prints only that one. The convention
  suite holds it to the backup name, the prune-after-save gate, the
  backup-before-install gate and the window and dry-run guards on every
  install and reboot line, and checks that neither it nor
  `backup_update_check.lua` declares an underscored `:global`.
  `print_schedulers.sh` gives it the 04:20 slot in place of the check it
  replaces.

- The RouterOS CHR suite runs on pull requests that touch `mikrotik/`,
  `run-tests.sh`, or `chr.yml`, alongside the nightly and on-demand runs. The
  nightly answers "does the pinned RouterOS still like these scripts"; it cannot
  answer "does this change work", because by the time it fires the change has
  usually merged. The path filter keeps the QEMU boot off every other pull
  request, and pull-request runs cancel when superseded while nightly and manual
  runs never do.

- `backup.lua` and `update_check.lua` have execution tests in the CHR suite,
  currently xfail: RouterOS 7.24.1 CHR refuses to run either script, because
  every execution path rejects a `:global` whose name contains an underscore and
  both have one. `/system script run`, `:parse` and `/system scheduler` all
  report "expected end of command" pointing at the underscore; `script add`
  accepts the source, so it is stored intact. QEMU was ruled out (identical
  under KVM) and so were permissions (an API-added script carries no policy,
  which masked the refusal for one round). The assertions are kept rather than
  dropped, so the coverage arrives on its own if a later release accepts the
  names. Adding a script proves RouterOS accepts the source, not that
  running it does what the file says — a weaker claim than it looks for the two
  scripts that respectively delete files and decide whether to tell you to
  upgrade. The backup tests assert the pair carries the router's own date and
  installed version, and that a seeded older generation is gone afterwards; the
  decoy is necessary because two runs on the same day at the same version write
  the same filename, so a second run overwrites rather than prunes and would
  pass a naive test while proving nothing. The update-check test asserts the
  timeout path sends a message and that the text carries no malformed percent
  escape. Both run through `:parse`, which is how these scripts invoke each
  other anyway and which sidesteps the CHR `/system script run` underscore bug.

- `:global UPDATE_CHECK_MAX_WAIT` sets how long `update_check.lua` waits for a
  verdict, in five-second units. A router on a slow or contended link
  legitimately needs longer, and a test that has to sit through the full 65
  seconds to watch the timeout path is a test nobody runs.

- `:global UPDATE_CHECK_NOTIFY_UP_TO_DATE true` makes `update_check.lua` send a
  short heartbeat on a quiet run - installed, latest, channel and RouterOS's
  own verdict - instead of only a log line. Quiet by default stays the default,
  because a router that says "nothing to do" every morning is the message that
  gets muted, and the one that matters gets muted with it. But a router that
  never speaks is indistinguishable from one whose scheduler quietly stopped,
  and on a router where that ambiguity is the worse problem the heartbeat is
  the answer. Opted into per router. Worded "nothing to install" rather than
  "up to date" because it also covers the channel-switch case, where the
  versions differ and there is still nothing RouterOS will offer.

- `backup_update_check.lua`: the update check with the pre-upgrade backup and
  prune, written so that it runs on RouterOS 7.24. The CHR suite has marked
  the execution tests for `backup.lua` and `update_check.lua` as expected
  failures because 7.24.1 refuses a `:global` whose name contains an
  underscore, and had recorded that as a CHR quirk. It is not: a router on
  that release failed `update_check.lua` the same way, with the same
  "executing script failed" and not one line of the script's own logging
  reaching the log. This script declares no such name - its only globals are
  `OpsToolboxPaused` and `RouterBackupPassword` - and was run end to end on a
  7.24.1 CHR, where it found a real newer release, wrote the pair, pruned a
  seeded older generation and delivered the message. It is the plainer design
  on purpose: a fixed 15-second wait rather than polling `status`, a message
  on every run rather than only on a transition, a `!=` test guarded against
  a failed check rather than RouterOS's own verdict, and the channel forced to
  `stable` on every run rather than only read, because that is the script an
  operator already trusted on that hardware, plus the backup.
  The Telegram helper's name is a setting and defaults to `tg_send_new`, the
  operator's own copy, because the package's `tg_send` declares `TG_BOT_TOKEN`
  and `TG_CHAT_ID` and so does not run on 7.24 either - a script that runs
  calling a helper that cannot is a message that never arrives. Install it
  instead of `update_check.lua`, not alongside it. The underscore refusal itself is now a known defect of most of
  this package on 7.24, not of the suite, and is left for its own change.

- `update_check.lua` reports the firmware, board, architecture, uptime, CPU,
  memory and storage figures alongside the version, and sends a message when
  the check itself fails rather than only logging one. Both are the questions
  somebody goes and answers by hand before deciding whether to upgrade tonight
  or at the weekend, and a check that silently never completes is a router
  sitting on an unpatched release with nothing saying so. The failure notice
  can only fire where the router still reaches Telegram, which is the case
  worth catching: DNS broken, the upgrade server refusing, a proxy in the way.
  `:global UPDATE_CHECK_NOTIFY_FAILURE false` turns it off.

- `update_check.lua` takes a backup before it tells you an upgrade is
  available, and names the resulting file in the same message. The snapshot
  worth having is one taken while the router still runs the version being
  replaced, and it needs to exist by the time somebody reads the notification
  rather than depending on them remembering. The save is inline rather than a
  call out to the `backup` script, so a router where only this script was
  pasted still gets a rollback point instead of a message saying the backup
  failed; the name is `backup-IDENTITY-DATE-VERSION-pre-upgrade`, carrying the
  date and the running version, which is the release the file restores. The
  `backup-` prefix is kept so `pull_router_backups.sh` still collects the pair
  and `backup_file_cleanup.lua` still ages it out — a differently-named file
  would be one nothing collects and nothing deletes. Once the new pair is
  written it removes the older `backup-*` files and reports how many, leaving
  one generation on a router whose flash is measured in tens of megabytes and
  which is about to need the space. The removal sits inside the success branch
  and after both writes, so a save that failed jumps to the error handler and
  can never be the run that deletes the last good backup; exclusion is by name
  because the files just written are known by name and RouterOS script has no
  sort to order the rest by age. The sweep keeps everything starting with the
  new base name rather than the two exact names `.backup` and `.rsc`, because
  `/export file=` writes through a `<name>.rsc.in_progress` temporary and
  returns before the export has finished — an exact-name test leaves that file
  matching `^backup-` and excluded by neither name, so the prune deletes a
  half-written export. Found by running the block against a CHR rather than by
  reading it: the temporary is real, outlives the command that created it, and
  the first run survived only because the sweep happened to win the race. It
  reads the same `:global
  BACKUP_REMOVE_PREVIOUS` as `backup.lua`, because how many generations live on
  a router is one policy and not two. `:global BACKUP_PASSWORD` encrypts it, the same global
  `backup.lua` reads; `:global UPDATE_CHECK_BACKUP false` goes back to
  notify-only. A failed backup does not suppress the update notification: it is
  reported, because "there is nothing to roll back to" is the thing you most
  need to know before upgrading. The convention suite pins the name, because a
  rename is the kind of edit that looks cosmetic and silently produces the one
  backup nothing collects and nothing ages out.

- `backup.lua` removes the previous generation once the new pair is written
  (`RemovePrevious`, off via `:global BACKUP_REMOVE_PREVIOUS false`). Exclusion
  is by exact filename rather than by timestamp, because the two files just
  written are known by name and RouterOS script has no sort to order the rest
  by. The sweep runs only after a successful save — the failure path ends in
  `:error` first — so a backup that failed never deletes the last good one.
  This is retention on the router, not a backup policy: it leaves one
  generation, so keep the rest off the device with `pull_router_backups.sh`.

- Dependabot watches the Docker base images as well as the actions. Every suite
  that runs anything builds it on one, and they were watched by nothing — the
  same mutable-tag argument the actions entry already makes, applied to the
  images the tests stand on. The entry globs directories rather than listing
  them, so a Dockerfile added later is covered by the commit that adds it.
  Coverage is partial by nature: Dependabot compares version-like tags, so
  `alpine`, `python`, `ruby` and `golang` move, `debian:bookworm-slim` is a
  codename with nothing to compare, and `linux/tests/tester` takes its base
  from a build argument that has no literal to read.

- A static check that every value-taking flag accepts both `--flag VALUE` and
  `--flag=VALUE`, in `test-env/static/check_conventions.sh`. `CONTRIBUTING.md`
  has asked for both spellings all along and nothing held anyone to it, which is
  how the divergence below survived. It is static rather than executed because
  proving the accepting half means running a script with a real value, and these
  scripts change machines. 94 flags across the tree pass.

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

- `stay_fresh.sh --only ai-caches` clears disposable Codex, ChatGPT, Cursor,
  and Windsurf caches without treating all AI data as temporary. It
  skips a tool while its process is active, fails closed when process state
  cannot be inspected, and preserves credentials, settings, conversations and
  project sessions, extensions, Codex runtimes, and local models. The
  LaunchAgent's conservative profile includes the step, so these caches are
  handled on schedule without broad user-cache deletion.

- Task-scoped conventions in an agent skills directory on a local checkout, so
  an automated coding agent working here loads the rules for the file in front of
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
- `stay_fresh.sh --force-system-caches`: the only way to reach
  `/System/Library/Caches`, and even then only on a machine that reports SIP
  positively disabled, and never the boot caches.
- `stay_fresh.sh --prune-unavailable-simulators`: the only way to run
  `simctl delete unavailable`. Without it those devices and their data are
  reported and kept.

### Changed

- `backup_update_check.lua` marks the one outcome that wants an operator:
  "update is required" now carries the word `ALARM` on its own line under the
  headline. The daily heartbeat and the failed-check notice do not, and the CHR
  suite asserts both halves — the alarm present with the newline that puts it on
  its own line, and absent from every other outcome. A router offering an
  upgrade and a router with nothing to do used to open with the same sentence,
  differing only in the word "not", which is the difference a phone notification
  is worst at showing.

- New changelog entries are files under `changelog.d/<type>/`, one per
  change, instead of edits to the top of `[Unreleased]` in `CHANGELOG.md`.
  Every pull request inserted at the same line, so any two open at once
  conflicted the moment one merged; the four open on one day cost six
  resolutions and a CI cycle each. `changelog.d/changelog.sh preview` prints
  the section as it will read, `check` validates every fragment and runs in
  the static suite, and `release VERSION` moves the fragments and the
  entries still in `[Unreleased]` under a dated version heading and deletes
  the fragment files. The entries already in `[Unreleased]` stay where they
  are until the first release moves them.

- `changelog.sh release` accepts only a `MAJOR.MINOR.PATCH` version newer than
  the latest one already in `CHANGELOG.md`. It used to take any single token,
  so `1.0`, `v1.0.0` or a version below the last release would each have been
  written as a section heading, and the version is now also a tag name. The
  comparison is numeric per field, so `1.10.0` counts as newer than `1.9.0`.
  Pre-release suffixes are refused rather than ordered wrongly.

- CI runs the no-Docker suites on the macOS runner, and a `templates/` change
  runs everything. `macos-15` is the only runner where BSD userland meets the
  test harness, and it was running one file; `static`, `k8s` and `dotfiles`
  now run there too, with a gate wide enough that a `test-env/` change wakes
  it. A `templates/` change previously matched no suite at all, so the two
  suites written to keep the templates from drifting ran on every change
  except the one that mattered. `Test / windows native` also gained the
  `Require pwsh` guard the Ubuntu matrix entry already had, without which the
  job passes over a runner that skipped itself.

- `git/tests/test_git_scripts.sh` no longer runs under `set -e`. A suite that
  aborts on the first non-zero exit reports the shell's status and discards the
  output it had just captured, so the real error never reaches the log; the 31
  `set +e` / `set -e` sandwiches the file had grown were the evidence of a
  running fight. Every failure is now a named assertion, the eight invocations
  whose result was judged only by what the filesystem looks like afterwards are
  guarded so a run that died on line one cannot read as "changed nothing" —
  `git_amend_last.sh` was the worst of them, with all three assertions after it
  holding just as well for the commit it was supposed to change, and the
  restored pre-commit hook the next worst, because the installed hook ends in
  `exit 0` of its own and satisfies the assertion that an uninstall ever ran.
  Scratch space is proven once at the top, where a failed `mktemp` would
  otherwise leave the path empty and point `cd "$repo"` at the checkout itself,
  and each `section` fails if it closes having asserted nothing. Same 269
  assertions, in 26 sections.
- `check_conventions.sh` now excuses one suite rather than two, and counts the
  excused from the list instead of saying "2" in a message that the next
  conversion would have made wrong. `CONTRIBUTING.md` names the macOS native
  suite as the last file still carrying the sandwich.

- `linux/tests/test_linux_scripts.sh` no longer runs under `set -e`. A suite
  that aborts on the first non-zero exit reports the shell's status and
  discards the output it had just captured, which is how a Bash 3.2 parse
  error reached CI as "exit code 2" and nothing else; the 197 `set +e` /
  `set -e` sandwiches the file had grown were the evidence of a running
  fight. Every failure is now a named assertion, the five invocations whose
  result was judged only by the filesystem afterwards are guarded so a run
  that died on line one cannot read as "changed nothing", scratch space is
  proven once at the top, and each `section` fails if it closes having
  asserted nothing — which found one straight away: the "dry run changes
  nothing" heading covered only a helper, its assertions having ended up
  under the Kali heading inserted between them. Same 334 assertions, in 27
  sections.
- Two RouterOS suites had `set +e` / `set -e` sandwiches in files that never
  enabled errexit. `set -e` is not scoped to the function it appears in, so
  the first `run_case` call turned it on for the rest of the file and every
  unguarded command after it became an abort with no message (`$-` read
  `ehuB` after the first call). The sandwiches are gone; the files run as
  their first line says.
- `check_conventions.sh` now fails an assertion suite that enables errexit.
  The two not yet converted (`git/tests`, the macOS native suite) are named
  as exceptions, and a name on that list must still carry a `set -e`, so the
  list cannot outlive the last file it excuses. `CONTRIBUTING.md` no longer
  prescribes the sandwich.

- `macos-initial-setup/tests/test_macos_initial_setup.sh` no longer runs
  under `set -e`. This is the suite that taught the lesson: an unguarded
  capture of `stay_fresh_agent.sh logs` met a Bash 3.2 parse error in the
  script it was calling, and the macOS job reported "exit 2" and nothing
  else — no failing assertion, no message, and every check below it silently
  unrun. The diagnosis arrived only after that one call site was wrapped in
  `set +e` by hand, and the 84 sandwiches the file had grown were the rest of
  the same fight. Every failure is now a named assertion, so the parse error
  is reported as the assertion that saw it; scratch space is proven once at
  the top instead of at sixteen `mktemp` sites; and each `section` fails if it
  closes having asserted nothing — which found one straight away, the
  "stay_fresh safety contracts" heading that named a block building a fixture,
  its assertions having ended up under the krew heading inserted between them.
  Same 425 assertions, now in 24 sections.
- Thirteen invocations in that suite were judged only by what the filesystem
  looked like afterwards — a preview that must not have deleted a transcript,
  a reconciliation that must not have passed a destructive flag, a report that
  must not have rewritten its own history. A run that died on line one also
  changed nothing, so each of those assertions was one that could not fail.
  They are guarded now, and so is the one loop whose subject list came from a
  command that can fail rather than from a literal.
- With this, no assertion suite runs under `set -e`. `check_conventions.sh`
  drops the list of suites it excused while the three were converted one at a
  time — a list it policed in both directions, so it could not outlive the
  last file on it — and a suite that enables errexit now simply fails.
  `CONTRIBUTING.md` says so, and that a loop fed by a command needs a floor of
  its own.

- The RouterOS scripts are split into `mikrotik/core/` and
  `mikrotik/features/`, by whether this fleet runs them. `core/` holds the three
  that are deployed and scheduled — `backup_update_check.lua`,
  `detect_internet.lua`, and the Telegram helper they send through,
  `tg_send.lua`, installed under its own name (`backup_update_check` defaults
  to the operator's separate copy, `tg_send_new`). `features/` holds everything else
  the package offers and nobody has deployed: the other backup and update paths,
  the hardening audit, the watchers and notifiers, and the two host-side tools.
  Being in `features/` says nothing about quality — both folders are held to the
  same conventions and the CHR suite runs all of them — only that no running
  router depends on it yet. Nothing changes on a router: a script's name in
  `/system script` and `/system scheduler` is still its filename without the
  extension, so `backup_update_check` is what it was.
- Three discoverers only looked one directory deep, and two of them would have
  passed rather than failed once the files moved. The CHR suite globbed
  `mikrotik/*.lua` and carried `skipif(not SCRIPT_FILES)`, so the suite that
  loads every script onto a real router would have reported success having
  loaded none; it walks now, and an empty list raises instead of skipping.
  `router_doctor.py` listed one directory to decide which scripts a router
  should have, so it would have compared the router against nothing and found
  nothing missing; it walks the package now, skipping `tests/`, and the names it
  returns are unchanged because a router script's name carries no folder. The
  convention suite's `find -maxdepth 1` would at least have failed loudly, and
  now resolves each script by filename, so a script that moves between the two
  folders needs no edit there. Both suites resolve a name to exactly one file
  and treat anything else as a failure: the checks that read a script's source
  to assert on what it says used to build that path a directory at a time, and a
  missing file either raised at setup or - where the check captured grep output
  with `|| true` - reported success having read nothing. Two scripts sharing a
  filename now fails as well, because every discoverer in the package keys on
  the basename and would report on one copy while reading the other.
- The convention suite gained the check that keeps the split honest: a script
  sitting loose at the top of the package fails, and so does one in neither
  folder, with a floor that fails if the check inspected nothing.

- Every Python CLI now exits `3` on an unrecognised flag, the same as the Bash
  and PowerShell scripts beside it. They used `argparse`'s own convention of
  exiting `2`, and `check_conventions.sh` exempted them from the contract by
  file extension rather than fighting it. That was harmless while `2` meant
  nothing in particular, and stopped being harmless once the diagnostics began
  documenting an exit `2` of their own — `git_ignore_doctor.py` spends it on
  "not inside a Git repository", `git_remote_doctor.py` on "git config
  unavailable" — so a mistyped flag returned the same number as a real finding
  and a caller could not tell a typo from a diagnosis. The exemption is gone
  rather than documented, so the suite now holds all eight to it, the two
  templates included.
- `mikrotik/features/export_config.py` returns `3`, not `2`, when `--stdout`, `--diff`
  and `--commit` are combined or when `--show-sensitive` is passed with
  `--commit`. Its own docstring spends `2` on a failed preflight — ssh missing,
  the router unreachable — and `3` on bad CLI arguments, and both of those are
  bad CLI arguments. A caller that retried on "could not reach it" was retrying
  a flag combination that could never work.

- Every folder README now answers "what do I need" and "what do I run first"
  before it answers anything else. Thirteen of the twenty had no requirements
  section and nine had no quick start, and the two worst were the two largest:
  `mikrotik/README.md` and `git/README.md` ran to hundreds of lines without
  telling a reader how to begin. `mikrotik` and `k8s-toolbox` gained a
  contents list as well, and `windows/wsl`, `test-env/chef` and `test-env/go`
  gained one each. What the requirements say is read out of the scripts rather
  than assumed: which preflight exits `2` for a missing tool, which tool is
  optional and merely warns, and where a version floor is pinned — RouterOS
  7.24.2 in `mikrotik/tests/routeros-version.env`, WinGet 1.6 for
  `winget configure`, the Bash 3.2 that ships on macOS, and Python 3.9 because
  that is what `/usr/bin/python3` is there.

- The folder READMEs use one naming convention instead of three. Ten titles
  were Title Case (`Git Scripts`), a bare directory slug (`k8s-toolbox`,
  `test-env`) or sentence case; all are sentence case naming the package now,
  since the directory name is already visible in the path and the title is for
  a reader. `macos-initial-setup` called its table of contents
  `Table of contents` where every other package says `Contents`, and
  `mikrotik` called its script table `Files at a glance` where `git` says
  `Scripts overview` — the same two things now have the same two names.
  `windows/README.md`'s folder table had no heading at all, so it appeared in
  no contents list.
- `.github/CODEOWNERS` names an owner for every path, so GitHub requests a
  review automatically rather than leaving a pull request to be noticed.

- `routeros_version.py` exits `3` on an unrecognised flag, for every
  subcommand, like the other Python CLIs. It had kept `argparse`'s `2`, which
  this repository spends on a wrong environment; it sits under `tests/`, so the
  unknown-flag contract in the static suite never reached it.

- `backup.lua` runs on RouterOS 7.24. Its two globals are now `RouterBackupPassword` — the name
  `backup_update_check.lua` and `stay_fresh.lua` already read for the same
  secret — and `BackupRemovePrevious`; 7.24 refuses to execute any script declaring a
  `:global` with an underscore in its name, and it stops in the parser, so the
  scheduled job logged nothing and looked exactly like a run with nothing to
  report. Fifteen of the 28 `.lua` scripts are still in that state, down from
  sixteen.
- `update_check.lua` is retired on 7.24 rather than renamed: it declares six
  underscored globals and `backup_update_check.lua` already does the same job
  there. It stays unchanged and supported for 7.23 and earlier.
- **If you run both on 7.23, set both spellings.** The two scripts shared
  `BACKUP_PASSWORD` and `BACKUP_REMOVE_PREVIOUS` because how many generations
  live on a router is one policy and not two. `backup.lua` reads the CamelCase
  pair now and `update_check.lua` still reads the underscored one, so a 7.23
  router running both needs both set or they will disagree about retention and
  encryption. On 7.24 only `backup.lua` runs and only the new pair matters.
- `backup.lua`'s notification says `Encryption: none` when no password is set.
  A router whose startup script still sets the old `BACKUP_PASSWORD` reads an
  empty password after this change and writes plaintext; that cannot be
  recovered from inside the script, because the old declaration is what 7.24
  refuses to run, so the nightly message names it instead of passing for an
  encrypted backup.

- `SECURITY.md` says what a tag is: a snapshot of the tree on the day it was
  cut, with no backport branch behind it. The file already promised no response
  window, and the first tag would otherwise have implied the support contract
  that sentence exists to deny.

- `macos-initial-setup/stay_fresh.sh` upgrades Homebrew formulae but only
  reports outdated casks in routine runs. Explicit `--brew-casks` upgrades
  casks in a terminal after sudo preflight; `--brew-greedy` then includes
  self-updating casks. Headless, `--no-sudo`, and failed-preflight runs skip
  cask upgrades while preserving formula upgrades and cleanup.

- `stay_fresh.sh` now documents the warnings a clean machine still
  produces. SIP leaves Apple-owned directories under `/Library/Caches` that
  the system-cache step cannot delete, and `kubectl krew upgrade` exits
  non-zero when a plugin is already newest; both used to look like leftover
  work in the log. The user-cache refusals, a Trash without Full Disk Access,
  and a root-owned gcloud log directory are called out so the first two are
  not mistaken for the third.

- `macos-initial-setup/stay_fresh.sh` reduces terminal rendering overhead by
  avoiding subprocesses for short messages, summary labels, and the live timer.
  Cleanup behavior and output formats remain unchanged.

- `macos-initial-setup/stay_fresh.sh` adds a read-only `--cache-report` and
  opt-in `--deep-clean` for validated Conda archive, index, and log caches.
  Cleanup preserves saved application state, unmapped or active application
  caches, and Maven's local artifacts; stopped Docker containers now require
  `--prune-docker-containers`. Shared deletion checks reject unsafe roots,
  symlink redirection, unverified ownership, and mounted filesystems.

- `macos-initial-setup/tests/test_stay_fresh_steps.sh` already ran under
  `set -uo pipefail` with no `set +e` sandwiches, but its `section "..."`
  heading was cosmetic — an `echo`, no counter, no floor — in the largest
  suite in the repository, the one that runs `stay_fresh.sh` for real against
  scratch fixture homes. It now uses the same counting `section`/`end_section`
  helper as `linux/tests`, `git/tests` and the macOS native suite, and fails
  a block that closes having asserted nothing. Same 754 assertions, now
  counted and floored, in 38 sections.
- Six invocations judged only by what the fixture home looked like afterward
  — a dry run that must have written no history, a guarded run that must
  have posted no failure banner, a listing that must not have probed the
  backup state, a dry run that must not have listed services, a dry run that
  must have written no log despite a pending warning, and one whose own exit
  status was captured and then overwritten by the next call before it was
  ever read — could not fail: a run that died before doing anything satisfies
  every one of those "nothing happened" assertions just as well as a correct
  run does. Each now asserts its own exit status first. Same 754 real
  assertions plus these 6 new guards.

- `windows/cleanup/clean_disk_c.ps1` refuses to delete without `-Yes`, and
  `windows/setup/stay_fresh.ps1` skips the winget upgrades without it. Both
  are changed defaults: a bare `.\clean_disk_c.ps1` used to empty `%TEMP%`,
  the Windows Error Reporting queue and the thumbnail cache on the spot, and a
  bare `.\stay_fresh.ps1` went straight to `winget upgrade --all
  --include-unknown --accept-package-agreements --disable-interactivity`.
  Their Bash counterparts have always asked: `linux/disk_cleanup.sh` refuses
  without `--yes` and `linux/stay_fresh.sh` skips package upgrades without it.
  The README presents the two families as counterparts, which is what made the
  asymmetry dangerous rather than merely inconsistent — the habit learned on
  the Bash side is "just run it, it will tell me what it wants", and on
  Windows that habit upgraded or deleted for real, first time, with no
  preview. `-DryRun` is unaffected and still needs no `-Yes`; on
  `stay_fresh.ps1` every step other than the upgrades still runs, so a bare
  run remains a useful report. The gate is a `-Yes` switch rather than
  `SupportsShouldProcess`, because `CONTRIBUTING.md` rules `-WhatIf`/`-Confirm`
  out for these scripts and the hand-rolled `-DryRun` already covers the
  preview half.
- `windows/setup/stay_fresh.ps1 -Only` takes a comma-separated list of steps.
  It was a single `[string]` behind a `ValidateSet`, so `-Only Winget,Wsl` —
  the obvious thing to type, and what `linux/stay_fresh.sh --only` accepts —
  died during parameter binding with a message about the valid step names,
  which reads as though the names were wrong rather than the type. The list is
  split and validated in the body instead, so both `.\stay_fresh.ps1 -Only
  Winget,Wsl` and the `pwsh -File` form of the same line are accepted; an
  unrecognised step is still rejected by name, now with exit `3`.

- RouterOS CHR compatibility was bumped from 7.24.4 to 7.24.5 after the full Docker integration suite passed.
- RouterOS CHR compatibility was bumped from 7.24.2 to 7.24.4 after the full Docker integration suite passed.
- `stay_fresh_agent.sh`'s `safe` profile now also runs the two read-only
  reports, `os-updates` and `snapshots` (listing only; the agent has no
  sudo, so nothing is thinned). A pending macOS update and a pile of local
  snapshots are what a Mac accumulates without anyone noticing, and a
  scheduled verdict that said nothing about either was not worth reading.
- `stay_fresh.sh` keeps its steps in one table (id, skip variable, function,
  label, description) that drives `--list-steps`, `--only` and the run loop.
  Adding a step is one line there, a parser arm and a plan line; the three
  hand-maintained lists that had to agree are gone, and the Docker suite
  checks every listed id is one `--only` accepts and previews.
- `CHANGELOG.md` merges with `merge=union` (`.gitattributes`). Every pull
  request adds its entry at the top of the Unreleased section, so any two
  open at once collided on the same lines and the second to merge conflicted;
  four open pull requests meant six conflicts to resolve by hand. Union keeps
  both sides' insertions, which is safe here because the only edit pattern is
  a whole bullet inserted, never a line changed in place.
- `history.tsv` keeps its last 500 rows. One row per run adds up on a daily
  schedule, and nothing that reads the file needs more.
- `stay_fresh.sh` parses `--only`, `--notify` and
  `--prune-xcode-archives-days` through the canonical `require_value()` block
  the other `macos-initial-setup/` scripts copy, so the static suite's
  contract check covers it. An unknown option now prints the help to stderr,
  where `CONTRIBUTING.md` says it goes, and the gcloud step's dry run prints
  the package's `(dry-run)` preview lines instead of a `[dry]` prefix nothing
  else in the tree uses.
- RouterOS CHR compatibility was bumped from 7.24.1 to 7.24.2 after the full Docker integration suite passed.
- `stay_fresh.sh` sizes a sweep with one `du` for the whole set rather than one
  fork per path. `clear_paths` measures before and after, and its own comment
  notes that a sweep can match a few hundred directories — at that size the
  forks cost far more than the walking they do. Measured on 300 paths: 720 ms
  down to 22 ms for the sizing alone, and 936 ms down to 36 ms for a real sweep
  that sizes twice. Output is byte-identical in every mode, including the
  per-path lines under `--verbose`, which now take their path from `du` rather
  than from the loop variable so they stay correct whatever order it reports in.

  Measuring first killed the obvious change: dropping the `awk` from
  `path_bytes` to save a fork made it *slower* — 0.50 s to 0.61 s over 200
  calls — because `du` dominates and the command substitution costs more than
  the pipe it replaced. `path_bytes` is therefore unchanged, and still serves
  the six single-path callers where there is nothing to batch.

- The agent skills directory is local-only. It is gitignored and no longer
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

### Removed

- The `ai-caches` step no longer clears one vendor's desktop and CLI caches:
  its Application Support scan, its two bundle cache roots and its CLI cache
  root are gone, along with the process names that gated them. Codex, ChatGPT,
  Cursor and Windsurf are unaffected and still cleaned on the same terms. This
  is a deliberate narrowing of what the step touches, not a bug fix, so a
  machine that relied on those caches being swept now keeps them; delete them
  by hand, or add the paths back locally. The steps suite covers the remaining
  four, with Codex standing in as the tool that has both a desktop cache and a
  CLI cache.

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

### Fixed

- `stay_fresh_agent.sh run-scheduled --dry-run` deleted real logs. The
  rotation that keeps the ten newest transcripts sat below the
  `AGENT_DRY_RUN` guard on the run stamp with nothing guarding it, so
  previewing a schedule change destroyed the oldest records of what the
  schedule had actually been doing. A dry run now rotates nothing; it still
  writes its own transcript, which is the step list being previewed. The
  scratch file the rotation reads through is also checked before use: an
  unchecked `mktemp` on a full disk — the condition the agent exists to
  postpone — left the path empty, so the redirect and the loop each
  addressed a file with no name and the rotation quietly stopped happening.

- `stay_fresh_agent.sh install --ignore-power` was accepted, validated and
  reported as installed, but never reached the plist, so the agent it wrote
  went on deferring on battery and downgrading to reports while somebody
  typed — for good, and silently. The flag now travels into the
  `ProgramArguments` of the installed job. `status`, `run-now`, `logs` and
  `uninstall` have no firing to un-guard and swallowed it just as quietly;
  they now refuse it with exit 3, as their messages already promised.

- `stay_fresh_agent.sh status` told a healthy job it was dead after an
  upgrade. Only `run-scheduled` writes the `last-scheduled` stamp and only
  since the version that added it, so an agent installed earlier had none
  however faithfully launchd fired it, and its plist mtime tripped the
  staleness threshold. With no stamp the age is reported and the exit stays
  0; a stale stamp still fails as before.

- The "Bash 3.2 compatibility" section of `check_conventions.sh` skipped
  every file under `*/tests/*`, including
  `macos-initial-setup/tests/test_macos_initial_setup.sh` — the one test file
  the native macOS job hands to `/bin/bash` by absolute path, forcing the real
  3.2 interpreter, and whose own header already says it must stay Bash-4-free.
  A `declare -A` added there passed this check, passed every other gate, and
  would have failed only on a real Mac. That file is now scanned by name
  alongside the packages the section already covers; the rest of `*/tests/*`
  stays excluded on purpose, because none of the rest ever meets the real
  interpreter — most run inside a Linux container, two refuse to start
  anywhere else, and the packages reached through `run-tests.sh` on the native
  runner resolve a bare `bash` to a newer version that sits ahead of it on
  `PATH`. The section also gained a floor of its own: a probe it builds itself
  proves the scanner still catches a known-bad construct, and the check now
  fails outright, naming the gap, if it ever ends up inspecting zero files.

- `changelog.sh` could not be parsed by the Bash that ships on macOS, and the
  first attempt at fixing it was wrong. The cause is a `case` statement inside a
  multi-line `$( )`: Bash 3.2 parses `$(` by scanning for the matching `)` and
  miscounts on the unbalanced `)` closing each case pattern, so it dies with
  `syntax error near unexpected token 'newline'` and every `preview` and
  `release` assertion fails at once. The `case` is an `if` now.
- A conventions check refuses that construct repository-wide. It is valid Bash 4
  syntax, shellcheck is silent on it, and the Bash 4+ keyword scan looks for
  `mapfile`, `declare -A` and `${x,,}` — so nothing saw it but a macOS runner.
  Unlike the keyword scan this is not scoped to `BASH32_DIRS`: any script the
  static suite executes must parse under whatever `/bin/bash` the runner has.

- `changelog.sh` could not be parsed by the Bash that ships on macOS. A nested
  `$( ... do ... done )` sitting in a `case` pattern word inside another command
  substitution is valid Bash 4 and a syntax error in Bash 3.2, which is what
  `/bin/bash` is on macOS: the script died with `syntax error near unexpected
  token 'newline'` and every `preview` and `release` assertion failed at once.
  The label list is built before the substitution now. Nothing caught this
  because the Bash 3.2 convention check scans for version-specific *keywords*
  (`mapfile`, `declare -A`, `${x,,}`) and this is a parser incompatibility in
  otherwise ordinary syntax — only running the suite on a BSD box finds it,
  which is what the widened macOS job now does.

- `changelog.d/changelog.sh check` now reads the claims a fragment makes and
  not only the shape that would paste: a file named in backticks has to be in
  the tree, and a long flag standing alone in its span has to be one some
  script accepts — the scripts that entry names, or any script here when the
  entry names none. Two pull requests had shipped fragments for work nobody
  committed, one announcing an opt-in flag on
  `macos-initial-setup/v1_stay_fresh.sh` and one announcing two list flags on
  `macos-initial-setup/install_apps.sh`; both branches held nothing but the
  fragment, and both passed, because both would have pasted perfectly. A
  fragment was a promise nothing tested. The scoping is what makes it usable
  rather than noisy, and every form the fragments here already use stays
  quiet: a span with a space in it is a quoted command line, so the
  `brew --cache` and `apt-get --yes` they borrow belong to those tools and
  are not claims; an invocation such as `./x.sh` is prose about a usage line,
  not a file; runtime state like `last-run.json` is not a source file; and
  removal wording exempts the sentence it sits in, so an entry can still name
  what it deleted without exempting the next sentence with it. The check
  carries a canary through its own extractor, because one that quietly stops
  extracting reports a clean tree forever, and
  `test-env/static/test_changelog.sh` asserts each rejection alongside the
  true version of the same sentence.

- `changelog.d/changelog.sh check` and the paste disagreed about what a
  fragment is. `check` enumerated dot-files while the paste globbed only
  `*.md`, so a `.hidden.md` was counted and then silently dropped by
  `release`, and a `.DS_Store` or a vim swapfile in the working tree failed
  the whole static suite. Both now enumerate the same thing. A fragment of
  nothing but whitespace is also rejected rather than pasting two blank lines.

- `changelog.d/changelog.sh preview` printed two lines and exited 141. Its
  preamble reader exited at the first `###` heading while the writer was
  still pushing the section body into the pipe, so the writer died of SIGPIPE,
  `pipefail` promoted it, and `set -e` aborted the script with no message. The
  section only had to outgrow one pipe buffer, which it already had. It reads
  all of its input now.

- The RouterOS integration suite decides which scripts it expects to run from
  the scripts themselves, not from a hand-kept list of two names. A
  `:global` or `:local` whose name contains an underscore is what RouterOS 7.24
  refuses to execute, so that is what the marker now reads. The list had gone
  stale: `health_check` declares no underscored name and was still marked
  `xfail`, so every run reported `XPASS` — a test asserting the opposite of the
  truth, tolerated only because the marker is not strict. Each remaining Wave C
  rename now flips its own case with no edit to the suite.

- The `Detect changes` job published an empty test matrix and exited 0 when
  `run-tests.sh --list` failed, because a process substitution's exit status
  is invisible to `set -e`. Every required `Test / <suite>` check then went
  missing rather than red, leaving the pull request unmergeable with nothing
  to point at. An empty matrix is now an error.

- The `clone-repos.sh` example in `git/README.md` named `repos.txt.example`
  where the two lines above it are written to run from the repository root,
  so it exited 2 as written.

- `linux/config_backup.sh` validates private mode-0600 staged archives before
  publishing unique names without replacing existing files or following archive
  symlinks. Concurrent publication and retention are serialized; failed runs
  preserve previous generations, and explicitly named partial backups retain
  separately without evicting complete copies.

- `check_conventions.sh` reported that `set_git_profile.sh` accepts
  `--profile VALUE` but not `--profile=VALUE`, on a script that accepts both.
  The check asked with `printf … | grep -qx`: `grep -q` exits at the first
  match, which kills `printf` with SIGPIPE, and under `set -o pipefail` the
  pipeline reports 141 — so finding the flag was indistinguishable from not
  finding it. Whether the writer had finished before the reader left decided
  the answer, which is why it failed on macOS and passed on Linux. The same
  file carried four of these, and four more sat in `system_doctor.sh` and
  `linux/install_devtools.sh`, where the symptom was a stray
  `write error: Broken pipe` in otherwise clean output. All eight now read from
  a here-string, which has no writer to kill.
- A new check reads every tracked shell file that sets `pipefail` and fails on
  a pipeline into a reader that exits early. It reads rather than runs, so
  unlike the rest of the suite it also scans the test infrastructure — the file
  that had four of them would otherwise have gone on exempting itself.

- `linux/disk_cleanup.sh --include-trash` half-emptied the Trash, and missed a
  relocated one entirely. It walked `find -type f`, so a trashed directory lost
  its files and stayed behind as an empty skeleton while its `.trashinfo`
  record was deleted with them, leaving an item that could no longer be
  restored or even identified. And where `files/` is a symlink — the usual way
  to keep a trash off a small SSD — `[[ -d ]]` followed the link but find did
  not, so the run announced "nothing in trash files" and freed nothing at all
  on the machine most likely to need the space. Both directories are now
  emptied with the same `find "$dir/" -mindepth 1 -delete` that
  `linux/stay_fresh.sh` already uses, which descends into a relocated trash,
  removes trashed directories whole and leaves the two directories the
  FreeDesktop spec expects to exist. The byte total is measured in a pass ahead
  of the delete rather than counted one unlink at a time, so a dry run still
  reports what it would free and still writes nothing. The cache directories
  keep the old walk, which leaves their tree in place on purpose.

- `linux/disk_cleanup.sh --home DIR` deleted files outside `DIR`. The
  thumbnail step read `$XDG_CACHE_HOME` straight from the environment, so a
  run aimed at one profile emptied the cache of whoever invoked it — and
  `linux/tests/test_linux_scripts.sh`, which cleans a scratch profile, did
  exactly that to a developer's own thumbnails. With `--home` the ambient
  variable is now inert and the run says so; without it, it is still honoured.

- The macOS disk report measures again. It ran `du -a -k -x -d 1`, and BSD du
  spells its usage `[-a | -s | -d depth]` — the three are mutually exclusive and
  it exits 64, `EX_USAGE`, for any pair. So the step whose whole job is to say
  what is large had never produced a number on macOS: all ten roots printed
  "total unknown" and warned, ten warnings a run. GNU du accepts the pair, which
  is why the Linux container every suite runs in never saw it. The portable
  spelling is `-s` on the root and `-s` on each entry, which also keeps files —
  `~/Downloads` and `~/Movies` are where one large file is usually the answer.
- A root that du could only partially read reports the total it did read
  instead of discarding it. macOS keeps directories under `~/Library/Caches`
  and `~/Library/Containers` that the user cannot enter, so du prints a sum and
  exits 1 on every healthy machine; that was being treated as a failed
  measurement and warned about. It is a plain line saying "at least" now, and
  the largest entries under it are listed as they are for any other root.
- Paths in the report render as `~/Library/Caches`, not `\~/Library/Caches`. The
  replacement in `${path/#$HOME/...}` is held in a variable now, because neither
  literal survives both shells: bash 5 tilde-expands a bare `~` back into the
  real home path, and the bash 3.2 that `/bin/bash` is on macOS leaves `\~` as a
  literal backslash-tilde. The suite runs on bash 5 and saw the tilde it
  expected while every Mac printed the backslash.
- `test-env/static/check_conventions.sh` fails any script that combines two of
  du's `-a`, `-s` and `-d`, so the next one is caught where the suites run
  rather than only on a Mac.

- Link fragments into other documents are checked now, and four were dead.
  `test_doc_citations.sh` checked the path of a `](../other.md#section)` link
  and the fragment of a same-file one, but nothing checked a fragment that
  named another file. Three links spelled `#development--docker-checks` with
  the two hyphens of an older `&`-era title, long after the heading became
  `## Development: Docker checks`, and one pointed at `#testing-docker` where
  the root README says `## Testing`. A dead fragment renders as an ordinary
  link that scrolls nowhere, so reading never found them.

- The documentation citation suite now checks in-page anchors. It read line
  numbers, relative link targets, `fn()` citations and package README
  coverage, and threw the fragment away on every link it resolved: replacing
  a real `](#winget_bootstrapps1)` in `windows/setup/README.md` with
  `](#this-anchor-does-not-exist)` left the whole suite green. Twenty
  documents now carry a Contents list built from generated slugs, and a
  renamed heading orphaned every link to it in silence, because a dead anchor
  renders as an ordinary link that scrolls nowhere rather than as a broken
  one. Each heading outside a fenced code block is slugged the way GitHub
  does it — deleting the punctuation instead of replacing it, and numbering a
  repeated heading — and a link to an anchor no heading generates now fails
  the suite by name. Like every other section here it has a floor: collecting
  no headings, or no links, is reported as the check having stopped checking
  rather than as a pass.

- The macOS suite no longer fails according to the filesystem underneath its
  container. `step_downloads` totals with `du -sk`, which measures blocks on
  disk, and `du -sk` of a directory charges for the directory itself — one 4K
  block on ext4 and APFS, nothing on the overlayfs the tester usually runs on.
  The downloads fixture put a 64K file inside a directory next to a 2048K file,
  where that 4K decided the last digit: the total reads 2.06M or 2.07M
  depending on the host's Docker storage driver, and the suite asserted 2.07M.
  The fixture now lands on exactly 3.00M, far enough from the rounding boundary
  that the directory's block cannot move it. `stay_fresh.sh` was right all
  along — blocks on disk is the honest answer to "how much would this free".

- The dry-run filesystem check counted Homebrew's own cache as a script's write.
  A preview of `install_apps.sh` or `brewfile.sh` calls `brew info` to confirm a
  formula name resolves before planning to install it — a read — and Homebrew
  compiles its Ruby into `~/Library/Caches/Homebrew/bootsnap`, some 950 files.
  The scripts store nothing. That path joins the Go telemetry counters on the
  named exclusion list, along with the two bare parent directories Homebrew
  creates on the way to it, matched only where a path ends there so a real write
  to `~/Library/Preferences` still fails. It surfaced only once the snapshot
  started working on macOS: with GNU-only `find -printf` both sides were empty,
  so this had been happening unseen.

- The "a dry run writes nothing" assertions passed on macOS having inspected
  nothing. `check_conventions.sh` and `k8s-toolbox/tests/test_k8s_toolbox.sh`
  snapshotted the filesystem with GNU-only `find -printf`, whose error
  `2>/dev/null` swallowed, so the before and the after call both returned the
  empty string and every subject compared `""` to `""`. Both now fall back to
  one batched `ls -ld`, as `test_changelog.sh` and the dotfiles suite already
  did. The static suite covers 32 dry-run-capable scripts, so this was the
  contract's widest blind spot.

- `export_config.py` defaulted `--out` to a directory beside itself, so moving
  the file into `mikrotik/features/` moved the export history with it. An
  operator with stored exports would have written to an empty
  `mikrotik/features/config-history/` on the next run and diffed `--diff`
  against nothing, with no message and every previous export still in
  `mikrotik/config-history/`. The default is keyed off the package root, where
  the README says it is.

- The host-environment convention check now sees the whole repository. It read
  only `.sh` files, so a Python helper reading `os.environ` was invisible; it
  discovered only package `tests/` suites, so the `test-env/static/` ones were
  never asked; and it matched a script by name anywhere in a suite, so a
  suite's own comments counted as running it and a suite's prose about a
  variable counted as pinning it. Extraction moved into a single awk pass
  (`test-env/static/host_env_vars.awk`), which reads each file once and decides
  there: the two-stream comparison it replaces is the shape that made
  `changelog.sh preview` exit 141, and it had already cost this check a third
  of its subjects. Coverage went from 41 pairs to 53.

- The host-environment convention check exempted `check_conventions.sh`, the one
  suite that actually executes every script in the repository — `--help`, an
  unknown flag and a full dry run apiece. It pinned only `HOME` and `TMPDIR`, so
  eighteen variables reached those runs from the developer's shell, notifier
  tokens among them, and an `XDG_CONFIG_HOME` sent a dry run to the real
  `~/.config` where the scratch snapshot could not see the write. The suite is
  on its own list now and pins the rest; coverage went from 53 pairs to 71.
- `dotfiles/tests/test_dotfiles.sh` passed all thirteen configs without parsing
  any of them when `python3` could not start: the verdicts arrive through a
  process substitution, whose exit status the shell never sees, so no lines meant
  no failures. It now asserts one verdict per file.

- The foreign-variable check could not see a variable a script defaults to
  itself. `SYSTEMD_ANALYZE_CMD="${SYSTEMD_ANALYZE_CMD:-systemd-analyze}"` reads
  the host's value whenever the host has one, but `host_env_vars.awk` counted
  the assignment and cancelled the read, so the check reported nothing. That
  hid the worst member of the class: `stay_fresh_timer.sh` executes the binary
  that variable names, so an exported value aimed a suite's `verify` at
  whatever the developer's shell said. `install_devtools.sh` hid two more,
  `CPPFLAGS` and `LDFLAGS`, which it appends to and exports into a `pyenv`
  build. All three are pinned now, in the suites and in the check itself.
  The scanner distinguishes a defaulted read from a plain assignment, and from
  `VAR="$VAROTHER/x"`, which reads a different name that merely starts the
  same; both directions are asserted against a probe, so the check fails rather
  than passes if it stops scanning.

- `install_apps.sh` printed the wrong adopted count in its summary. The colour
  and the number were written as one word, so `%d` consumed the reset escape
  instead of the count and the line rendered `adopted:   00` — two digits for
  zero adoptions, and no colour reset after it. No suite could catch it: the
  summary sits past the `--dry-run` exit, so a dry run never reaches it, and
  `SC2183` is a warning that the error-severity ShellCheck pass lets through.
  Lint now runs a second ShellCheck pass on `SC2183` alone, across the same
  file list, so a `printf` given fewer arguments than its format wants fails
  the build rather than printing the wrong thing on every run.

- `install_apps.sh` and `install_devtools.sh` refuse a non-interactive
  real run that omitted `--yes`, the same contract `stay_fresh.sh`
  already enforced. Piped stdin used to count as consent and the
  installers proceeded; a preview still does not need `--yes`.

- Match JetBrains application bundle paths precisely so Apple's Aqua appearance
  helper no longer blocks explicitly selected obsolete IDE version removal.
  Actual IDE and Java helper processes still preserve version data.

- `stay_fresh.sh` warned once per kubectl plugin on a machine that was fully up
  to date. `kubectl krew upgrade` exits non-zero when a plugin is already at the
  newest version, which is the answer "nothing to do" — and on a current machine
  it is the answer for every plugin, so the step closed with a WARN verdict for
  doing exactly what it should. This package documented that exit code as
  expected rather than acting on it, which left the warnings in the log; a
  warning nobody should act on is what teaches people to skip the ones they
  should. The message now decides, a real failure still warns, and the step says
  how many plugins were already current.
- The same step puts `$KREW_ROOT/bin` on `PATH` for its own calls. krew prints a
  four-line `WARNING` on every invocation when that directory is missing from
  `PATH`, and a scheduled run has the environment launchd hands it rather than
  the one `~/.zshrc` builds, so a clean run carried three copies of it.

- `LINT_FETCH=1 ./run-tests.sh lint` can install actionlint and Hadolint on a
  Mac. Both fetchers asked for the `linux_amd64` asset whatever
  machine was asking, and `.github/ci-tool-checksums.env` recorded a digest for
  that platform alone, so on macOS the two were skipped as uninstallable and
  the local suite ran one linter of six — on the platform most likely to be
  running it. ShellCheck beside them had chosen its asset per platform all
  along. The digests for the macOS builds come from each project's published
  checksums file, including Hadolint's, which this repository had recorded as
  not existing and had therefore been pinning to a hash of its own download.
  The review-time check that every digest is read by something now counts
  `test-env/lint/run.sh` as a reader alongside `ci.yml`, deriving the tools and
  platforms it covers from the runner itself; a digest nothing fetches still
  fails.

- `linux/status.sh` asked systemd about `stay-fresh.timer`, a unit nothing
  installs. `systemd/stay_fresh_timer.sh` sets `NAME="ops-toolbox-stay-fresh"`
  and builds every unit path and `systemctl` call from it, so the section could
  never reach its ok branch: on a machine with the timer installed, enabled and
  running it told you to install the thing that was already installed. The
  branch is `info` rather than `warn`, so it moved no exit code and no test
  noticed.

- `linux/stay_fresh.sh` emptied the Trash by removing the `files/` and `info/`
  directories rather than their contents, which the FreeDesktop spec expects
  to exist. On a Trash relocated to another disk — `files/` a symlink, the
  usual way to keep it off a small SSD — it deleted the symlink instead: the
  trashed files stayed where they were, nothing was freed, the relocation was
  destroyed, and the run reported success.

- Nine places in `macos-initial-setup/` tested a pipeline ending in a reader
  that stops at the first match — `brew upgrade --help | grep -q -- '--yes'`
  and `tail -n +N "$LOG_FILE" | grep -q index.lock` in `stay_fresh.sh`, four
  `pyenv`/`goenv`/`brew tap`/`helm plugin list` probes in `install_devtools.sh`,
  and the `spctl`/`csrutil` reads in `workstation_doctor.sh`. Under
  `set -o pipefail` the reader's early exit kills the writer with SIGPIPE, the
  pipeline reports 141, and a match reads as a miss. Measured on this repo's
  runner, a writer whose output fits the pipe buffer finishes first and is
  unaffected: 0 of 25 runs lost the match up to about 120 KB, 25 of 25 from
  128 KB. None of these nine is failing today, so this is hardening rather than
  a repair — but which side of that line `stay_fresh.sh` falls on depends on how
  much `brew update` prints, which is a property of the machine's tap count and
  not of the code. All nine now use a here-string, which has no writer to kill.
- The macOS suite gained the check that finds this shape, with the floor every
  check in that folder carries: it fails rather than reports a clean sweep if it
  inspects no file. It is deliberately limited to pipelines in a *tested*
  condition, because SIGPIPE corrupts a pipeline's exit status and not its
  output, so `x="$(cmd | head -n1)"` is safe. The repo-wide check in
  `test-env/static/check_conventions.sh` cannot see any of these: its writer
  pattern is `(printf|echo)`, so `brew upgrade --help | grep -q` never matched
  it, and it reported a clean sweep over a class it was only sampling.

- `mikrotik/README.md` told users to set `TG_BOT_TOKEN` / `TG_CHAT_ID`, which
  nothing has read since the RouterOS 7.24 rename, and credited
  `router_doctor.py` with checking those same two names when it checks
  `TgBotToken` / `TgChatId`. Following the requirements table produced a
  router that stays silent. Both now name what the code reads.
- The scripts overview says which of the 27 run on RouterOS 7.24 and which do
  not. Sixteen die in the parser on that release over an underscored `:global`
  or `:local`, logging nothing, so a scheduled script that never runs looks
  exactly like one with nothing to report — and the README offered no way to
  tell the two groups apart. Both lists and the headline count are derived from
  the scripts and compared in `test_lua_conventions.sh`, so a script that
  changes sides fails the suite rather than quietly making the note wrong.

- MikroTik security reporting now separates observed configuration from inferred exposure: LAN DNS is no longer treated as an open resolver, disabled/invalid firewall drops do not count as protection, management checks do not invent a subnet, and uncertain paths are reported as unknown. Update notifications now distinguish a release being available from it being required, can attach an operator-reviewed reason to an exact version pair, and only acknowledge Telegram delivery after the API returns success.

- The npx cache tests run on macOS. `safe_root` walks the cache's ancestry with
  `lstat` and refuses a symlinked component, which is the guard that stops a
  redirected ancestor aiming the sweep somewhere else. The fixture handed it a
  `tempfile` directory, and on macOS that sits under `/var/folders` while `/var`
  is a symlink to `/private/var` — so all seven tests raised
  `Unsafe("cache ancestry is not a real directory")` before reaching anything
  they meant to check. The fixture resolves the path now; the guard is
  unchanged, because it was right. Linux has a real `/tmp`, which is why CI
  stayed green while the suite could not run on a Mac at all.

- `test-env/static/run.sh` did not pin `PIN_MAX_AGE_DAYS`, the threshold that
  is the whole of `check_pin_age.sh`. Exported by a developer or a runner it
  silently redefined "too old" while the check still printed `[ ok ]` for every
  file — the same shape as the `CHANGELOG_ROOT` leak beside it. The suite glob
  that should have caught it matched `test_*.sh` and `check_conventions.sh`
  only, so a file named `check_pin_age.sh` was in no subject list; it now
  matches `check_*.sh`.

- `k8s-toolbox/kubectl_pod_diag.sh` reports unready Running containers,
  failing init containers, and unhealthy restartable sidecars, and fetches
  crash logs from the named failing container. Warning lookback uses the latest
  observation before the first event time. Failed queries, malformed JSON,
  and unusable event timestamps report an incomplete check instead of quiet
  health; remaining sections still run. Current container log requests also
  work under Bash 3.2 when there are no optional log flags.

- Disable Python bytecode writes during LaunchAgent plist inspection and Conda
  metadata parsing, keeping maintenance previews free of interpreter cache files
  on macOS. Ignore ambient Python import settings for these internal parsers.

- `git/git_prune_gone.sh` limits gone-upstream pruning to the selected remote,
  requires `--allow-unmerged` for tips not reachable from HEAD, and preserves
  every candidate tip in durable recovery refs before deleting any branch.
  Full-SHA restore commands remain usable after reflog expiry and garbage
  collection; a bounded recovery store and failed backup creation stop deletion,
  while current, worktree, protected, and symbolic branches remain guarded.

- Retry unchanged rogue DNS alerts until Telegram explicitly acknowledges delivery, send external values as literal plain text, and use RouterOS 7.24-compatible global names with documented scheduler policy and configuration migration. Treat missing substring matches by result type and preserve alert state when router-address or client-connection observations are incomplete.

- Export RouterOS configuration through a private 0600 staging file and atomic replacement, rejecting existing symlinks and preserving old exports on failure. Pull backup/export files independently through staging so missing patterns or a successful sibling cannot hide a failed transfer or overwrite a good generation with partial data.

- `router_doctor.py` could report the deployed scripts as strangers. It walks
  the package to learn which scripts should be on the router, and `os.walk`
  swallows a per-directory read error and keeps going, so an unreadable
  `core/` produced a list that looked complete and was short — every name it
  lost then showed up as a script the router has and the package does not, in
  a tool whose whole job is to say what is missing. A directory that cannot be
  read is now an error (exit 2, in both text and `--format json`); a directory
  that is simply not there still returns nothing, because the script has to
  survive being copied on its own into `~/bin`.

- `routeros_version.py record-hash` retried a host the instant a transfer
  failed, which was meant to match the Dockerfile's `wget --tries=3` but did
  not: wget waits between tries, and a retry fired at once usually meets the
  CDN edge that just cut the transfer in the same state. It now pauses two
  seconds before the second attempt and four before the third. A 404, or any
  4xx other than 408 or 429, moves to the next mirror at once instead of
  spending the remaining attempts on a file that is not there.

- The two RouterOS discoverers disagreed about what a test fixture is. The CHR
  suite drops any directory named `tests` at any depth; the convention suite
  dropped only `mikrotik/tests/`, so a `.lua` under `features/tests/` was held
  to the script conventions by one and never loaded onto the router by the
  other. Both use the same rule now.

- The aggregator's contract tests never ran a failing suite. Every fake
  runner `test-env/static/test_run_tests.sh` built exited 0, so the one
  property each CI verdict rests on — a failing suite makes `run-tests.sh`
  exit non-zero and record `"status":"fail"` in the JSON summary — was
  asserted nowhere, and a regression in `run_suite` or in the summary
  writer would have kept every `Test / <suite>` job green while the suites
  underneath it failed. The fakes now record that they ran and what they
  were handed, so a skipped suite can no longer be mistaken for a failing
  one, and the checks cover a failing suite, a run mixing a failing suite
  with a passing one named after it, the `--` passthrough the CHR
  workflows depend on, the `--summary-file=VALUE` spelling, and that
  `run-tests.sh all git` runs the git suite once rather than twice.

- A scheduled `stay_fresh.sh` run that could not start said so to nobody. The
  end-of-run notification lives past the step loop, so every guard that exits 2
  before it — not macOS, running as root, no terminal without `--yes`, `HOME`
  unset, and another run holding the lock — was silent on the macOS banner,
  Telegram and Slack alike. A schedule that has stopped doing anything then
  looks exactly like a schedule with nothing to do, which is the failure the
  notification path exists to prevent. Those paths now send one
  `stay_fresh FAILED: <reason>` notification first. It is deliberately not
  gated by `--notify-when`, because `warn` and `fail` describe the verdict of a
  run that ran and a run that could not start has no verdict; `--notify none`
  still silences it. Only the macOS banner is used when `HOME` is unusable,
  since the Telegram and Slack credentials are read from under it.
- The LaunchAgent sent both of its standard streams to `/dev/null`, so a firing
  that died before it could open its own log — the checkout moved and the
  script is no longer where the plist points, a log directory that cannot be
  created — stopped the schedule with no output anywhere. stderr now lands in
  `~/Library/Logs/stay_fresh/agent-launchd.err`. stdout stays discarded: a
  healthy run's chatter is already in its own timestamped transcript.
- `tmutil status` ran as a bare command substitution in the snapshot step, the
  one probe there that `--step-timeout` could not reach. It talks to backupd,
  and on a Mac whose Time Machine destination is an unreachable network share
  it blocks and takes the run with it. It now goes through `capture_cmd`, and
  the failure path changed with it: the old code left the status empty on
  error, so the "is a backup running" test did not match and the run thinned.
  Once a hang becomes a timeout that would mean thinning under a backup it
  could not see — the exact outcome the guard exists to prevent, and worse than
  the hang. A probe that cannot answer now keeps the snapshots.
- The macOS suite's own `bash -n` check ran under the wrong interpreter.
  `Test / macos native` starts the suite with `/bin/bash` — the Bash 3.2 every
  Mac ships, and the only interpreter in CI that parses the way a user's
  machine will — but the check shelled out to a bare `bash`, which resolves
  through `PATH`, and that runner has Homebrew's Bash 5 ahead of `/bin`. So the
  one check whose job is to catch a Bash 3.2 parse error was asking Bash 5, and
  passed a file 3.2 refuses. It now uses `"$BASH"`, the interpreter actually
  running the suite. This was found the hard way: an apostrophe added to the
  LaunchAgent plist heredoc parsed cleanly under Bash 5 everywhere, and 3.2 —
  which does not treat a heredoc body inside `$( )` as opaque — read it as an
  unterminated quote and followed it to end of file. The suite then died at the
  first script it ran, reporting the shell's exit code and nothing else.
- CI gained the check that would have caught all of this: a
  `Parse with Apple Bash 3.2` step on `macos-15`, the only runner with a real
  `/bin/bash` 3.2. It calls that interpreter by absolute path — a bare `bash`
  there is Homebrew's 5, which is the whole problem — over every tracked script
  in the directories `CONTRIBUTING.md` requires to be 3.2-clean, with the same
  `*/tests/*` exclusion `check_conventions.sh` applies to `BASH32_DIRS`. It is
  gated on its own `bash32` path filter rather than by widening `native_macos`,
  because `git/` and `linux/` need the parse check and do not need the macOS
  suites: seconds instead of seven minutes. Before this, a construct Bash 3.2
  refuses had no job anywhere that could see it — `Lint` runs `bash -n` on
  Ubuntu, the static check greps for keywords rather than parsing, and the one
  job with Apple Bash did not even run for a change to `git/` or `linux/`. Two
  floors: the step fails if `/bin/bash` is no longer 3.x, and fails if its
  globs match no file, because either would leave it passing while checking
  nothing.

- A script with a shebang that nobody could run passed every check.
  `check_conventions.sh` asked whether an executable file earns its bit and
  never the converse, so `status.sh` arrived tracked 644 — reviewed and merged
  as a script you had to say `bash` in front of, while every usage line in the
  repository is written `./x.sh`. The check now runs both ways, exempting
  files whose own header says "Sourced, not executed" rather than matching on
  a path. It found `mikrotik/tests/routeros_version.py` the same way:
  `mikrotik/tests/run.sh` tells you to run it as `$HERE/routeros_version.py`,
  which could not work.

- `security_check.lua` wrote its emoji as `\\F0\\9F…`, a doubled backslash,
  where every other script in the folder writes `\F0\9F…`. RouterOS reads
  `"\F0"` as the byte and `"\\F0"` as a backslash followed by the letters F and
  0, so every finding in the Telegram report carried literal `\F0\9F\9F\A0`
  text instead of the severity marker it was meant to show — 126 of them. A
  convention check now holds every script to the single-backslash form, skipping
  comments, where `reboot-and-flush.lua` documents a shell command whose own
  quoting needs the doubled spelling.

- `security_check.lua` said only `tg_send unavailable` when its report did not
  go out, with one `:do` block around both the parse and the call — the same
  sentence whether the helper is missing, refuses to parse, or raises while
  sending. A security audit that goes quiet for an unknown reason is the exact
  failure this script exists to prevent, because a missing report looks like a
  clean result. The two halves are now separate, the send resolves the helper's
  name through a variable and parses it once (the shape `backup_update_check.lua`
  proves end to end on a 7.24 CHR), and `SecSendError` records which half failed
  so a scheduler or a test can alert on it.

- `security_check.lua` lost its posture fingerprint whenever the Telegram
  helper raised. The call to the helper sat outside `:do{}on-error={}`, so a
  raise mid-send propagated and killed the script before `:set SecLastFp` —
  and a scan that forgets its own fingerprint reports `initial scan` on the
  next run instead of the posture change it exists to report. One Telegram
  outage was enough to make the audit blind to a change that happened during
  it. The call is now wrapped, as all three send sites in
  `backup_update_check.lua` already were. The comment that justified leaving
  it unwrapped claimed `backup_update_check.lua` calls its own helper from a
  plain `:if`; it does not, and the send that appeared to need the unwrapped
  form was failing for two unrelated reasons since fixed — the test installed
  no `tg_send_new` stub, and it drove the script through
  `/system/script/run`, which this CHR refuses for any source declaring an
  underscored `:global`. `SecSendError` now distinguishes a helper that
  raised from one that never returned, and the CHR suite covers the raising
  case. `SecSendError` and the new `PuTgStubReached` join the globals the
  session cleans between runs.

- `security_check.lua` never sent its report. It called `tg_send`, the package's
  older helper, while the two other scripts that run on RouterOS 7.24 —
  `backup_update_check.lua` and `stay_fresh.lua` — both default to `tg_send_new`,
  the operator's own copy and the one a 7.24 router actually has. It now does the
  same, with `SecuritySendScript` to name a third.

- `test-env/static/run.sh` let the host environment aim its changelog check.
  `changelog.sh` reads `CHANGELOG_ROOT` as the directory holding `CHANGELOG.md`
  and `changelog.d/`, so a developer with it exported had the static suite
  validate another checkout's fragments and report them green. The runner now
  unsets it, and the host-environment check that exists to catch exactly this
  now covers `test-env/*/run.sh`, which its subject glob had missed.

- `macos-initial-setup/stay_fresh.sh` applies command timeouts to Homebrew
  identification, upgrade-capability and repository probes, and reports failed
  post-upgrade cask verification as incomplete. Docker regressions exercise
  hung probes, the full interactive cask cycle, and real open-file detection.
- The macOS user/system log guards accept lsof's normal unmatched-file status
  only with no diagnostics and a valid open-directory witness, allowing closed
  logs to be removed while open files remain protected.

- `macos-initial-setup/stay_fresh.sh` explains old-log and npx candidates in
  verbose previews, revalidates npx entries after sizing, preserves confirmed
  partial log-removal counts, and reports outdated formulae while retaining pins.
- Cleanup guards reject unsafe npx ownership and permissions. Scheduled active-user
  reports omit recursive disk sizing; native and privileged fixture tests cover
  cleanup helpers. Docker and System Data explanations distinguish disposable
  caches from retained data.

- `stay_fresh.sh` probed `docker info` twice, once in preflight and once
  inside the docker step. A daemon that hung on the second probe held the
  run lock for another `--step-timeout` (default 30 minutes). The step drops
  the second probe and checks the exit status of `docker system df` instead —
  the size line it prints anyway, and the first call in the step that has to
  reach the daemon. `docker context show`, which the step still runs to find
  out whether the endpoint is local, reads the CLI's own context store and
  never opens the socket, so it cannot tell a live daemon from a dead one: a
  daemon that went away after preflight left each prune to discover that
  separately, warning rather than failing, so the step ended WARN and the run
  exited 0 — and waiting a full `--step-timeout` per command first if the
  daemon hung rather than died.

- A macOS `stay_fresh.sh --dry-run` no longer reports a reclaimed total. The
  summary subtracted the free-space reading taken at the end from the one taken
  at the start and printed it, in green, as `(N reclaimed)` — but a dry run
  deletes nothing, so that delta is whatever else the machine did while the run
  was going. On a busy Mac it is negative, which put `(-478.43M reclaimed)` in
  green directly above `steps freed: 0B` on a preview that had removed nothing.
  Both readings are still shown, without the claim. `history.tsv` and
  `last-run.json` were already skipped for dry runs, so `--trend` was never
  affected.
- A real run whose free space went *down* — something else wrote more than the
  sweep freed — reports that in yellow rather than green. It is a fact worth
  printing and not a win.
- The run log path no longer renders with a doubled slash
  (`.../T//stay_fresh-....log`) on macOS, where `TMPDIR` already ends in one.
  It appeared in the preflight line and in the warnings naming the directory.
  `linux/stay_fresh.sh` carried the same line and gets the same fix.
- The plan table lines up. `run` is three characters and `skip` is four, and
  neither was padded, so the DETAIL text on every `run` row sat one column left
  of the `skip` rows around it. The header also called the whole right-hand
  side `STATUS`, which named the verb and not the sentence beside it; the
  columns are now `STEP`, `DO` and `DETAIL`.
- Each step header carries its position — `==> Dev-tool caches [16/23]`. On a
  run where Homebrew and Xcode take minutes apiece, the step name alone does
  not say whether the run is a third of the way through or nearly done. The
  total is counted by the plan rather than kept as a second list, and the suite
  asserts the two cannot drift.
- The horizontal rule is drawn to the width of the terminal (clamped to 100)
  instead of a fixed 62 dashes, which fell short of a full line on a wide
  terminal and wrapped onto a second two-dash line on an 80-column one. Only
  when a terminal is attached: captured output keeps the bytes it had.

- `macos-initial-setup/stay_fresh.sh` validates and removes npx entries one at
  a time after sizing, preserving entries refreshed between removals. Its
  internal cleanup mode cannot be overridden by the environment, and a missing
  cache root fails final validation. Verbose system-log checkpoints omit the
  repeated candidate inventory while retaining confirmed removal records.

- `stay_fresh.sh` measured free space on `/`, which since Catalina is the
  sealed System volume, while every byte it deletes is on the Data volume where
  `$HOME` lives. The two usually share one APFS container, so the figure was
  right by construction rather than by measurement — and wrong for a `$HOME` on
  another volume, another container or an external disk, which is the machine
  whose owner is watching it. Both readings, the reclaimed total in the summary
  and the free-space column carried into `history.tsv` and `last-run.json`, are
  now taken on the volume that holds `$HOME`. A run that cannot read it still
  reports no measurement rather than a zero.

- Native macOS testing of `macos-initial-setup/stay_fresh.sh` identified
  valid lsof file-descriptor fields that the log guards rejected. Both parsers
  now accept validated descriptor fields while retaining the directory witness
  requirement. Native CI covers real lsof and process-list output. Deep
  messenger previews use one installed-app inventory to avoid counting standard
  profile caches twice.

- `stay_fresh.sh` reported a live LaunchAgent as orphaned when its program path
  contained a character XML escapes. A plist stores `R&D Tools` as
  `R&amp;D Tools`, the path was compared to the filesystem in that spelling, no
  such file existed, and `--prune-orphan-agents` deleted a working agent. The
  five predefined entities are decoded before the path is judged, `&amp;` last
  so `&amp;lt;` does not decode twice.

- `stay_fresh.sh` no longer warns Clear system caches because `find` cannot
  state a SIP- or TCC-protected entry under `/Library/Caches`. Those entries
  were already kept; the verification `find` exits non-zero for the same
  refusal, and that exit was counted as a failed clear, so a healthy Mac
  finished WARN on every run. Only a child is ignored that way. `Operation not
  permitted` on `/Library/Caches` itself means the contents were never listed,
  and that still warns the step, as does any other verification error.
- A launchd plist that Python's XML parser rejects no longer dumps a
  traceback. When `plutil` can read it, the program is inspected; otherwise
  the plist stays uninspected and is not removed.

- `stay_fresh.sh` no longer reports WARN because a cache refilled itself.
  `/Library/Caches` is rewritten by running daemons within the same second it
  is cleared, so the check for leftover entries fired on every healthy Mac and
  the run's verdict was permanently yellow — the state the script's own comment
  above `warn_step` exists to prevent, since a verdict that is always yellow is
  one nobody reads. Entries that are back with nothing denied, nothing errored
  and nothing protected are now a plain warning that says what happened; a
  failed removal and an entry owned by another user still warn the step.
- The message no longer offers "protected or recreated" for entries that were
  never protected.
- Applications found running are listed comma-separated. `"${running[*]}"`
  joins on a space, so `Visual Studio Code` and `Brave Browser` arrived as one
  unbroken run of words naming an application nobody could look for.

- `stay_fresh.sh` emptied nothing when the Trash had been relocated. A Trash
  moved off a small internal SSD is a symlink: `[[ -d ]]` follows it, but
  `find -P` does not descend into a symlinked start point and `du` does not
  measure through one, so the step walked nothing, deleted nothing, and printed
  "freed 0B" as though the Trash had been empty — on the machine most likely to
  need the space. `~/.Trash`, the verification pass and each mounted volume's
  `.Trashes/<uid>`, including the probe that decides whether a volume is worth
  opening, now carry the trailing slash `linux/stay_fresh.sh` already used.
  The comments in `linux/stay_fresh.sh` and `linux/disk_cleanup.sh` that named
  the macOS script as the reference for that form were describing something it
  did not do; they now say which file they mean and what it does.

- Two ways a scheduled `stay_fresh.sh` run turned red on a machine with
  nothing wrong. The brew step takes a line-count mark on the log before
  `brew update` and reads what came after it for a git lock; a mark that could
  not be taken (`wc` failing, an unreadable log) fell back to 0, so the reader
  started at line 1 and attributed every earlier step's output to brew — an
  `index.lock` mentioned by the docker step became "brew update did not
  refresh the taps", a `warn_step`, and under the LaunchAgent's
  `--fail-on-warn` a failed daily run. The mark now carries whether it is
  real; when it is not, the detector says it is not checking, as `info`, and
  the three counting readers keep their fallback because they match shapes
  only brew emits. And the Downloads step raised `warn_step` for an unreadable
  `~/Downloads` or a missing scratch directory, then fell through to report
  "nothing in ~/Downloads untouched" as though it had looked. Both are `warn`
  now, and a scan that failed returns instead of reporting an answer it does
  not have; a prune that fails still counts through `clear_paths`.
- The rule behind that is now checked, not remembered: the steps
  `--reports` names — "the steps that change nothing" — may not call
  `warn_step`, because the scheduled run passes `--fail-on-warn` and a
  report that warns on an ordinary machine is how somebody learns to stop
  reading it. `check_conventions.sh` reads the `--reports` list and the step
  table from the script itself, so a step that joins or leaves the list is
  covered by the commit that moves it. Four floors: the scheduled run must
  still pass `--fail-on-warn` or the check says to retire itself, every listed
  id must resolve to a step function, zero functions inspected fails, and at
  least one sweeping step must call `warn_step` or the scan has stopped
  matching. The tree did not pass it: `step_downloads` was the finding above.

- `macos-initial-setup/stay_fresh.sh` preserves open and changed user logs,
  rechecks paths through directory descriptors, and counts actual unlinks.
  Homebrew locks stay when process inspection fails; upgrade totals compare
  installed versions, and skipped cask upgrades warn during a full cycle.
  `macos-initial-setup/launchd/stay_fresh_agent.sh` now routes its full profile
  through the same age-limited cleanup and update preset as manual maintenance.

- `macos-initial-setup/stay_fresh.sh` preserves unpublished run locks and checks
  ownership before releasing them, preventing concurrent maintenance during
  startup and stale-lock recovery. LaunchAgent inspection parses complete XML
  and binary plists and respects `Program` before `ProgramArguments`.
- Plugin discovery failures and timeouts count as warnings instead of empty
  inventories. Previews avoid plugin queries that can initialize state.
- `macos-initial-setup/launchd/stay_fresh_agent.sh` prints scheduled previews
  to stdout without creating transcripts, log directories or scheduled-run
  stamps, and leaves existing logs unchanged.

- `stay_fresh.sh` looked for local Time Machine snapshots on `/` alone, so a
  second APFS volume or an external disk could hold a fortnight of them while
  the run reported "no local Time Machine snapshots" and `--thin-snapshots`
  left them where they were. Every mounted local volume is now listed, counted
  and thinned, from the same mount table the Trash step already reads — a
  network share is skipped by its type before the path is touched. `tmutil`
  deletes by date rather than by volume, so a date two volumes share is asked
  for once, and what a thinning run achieved is measured by listing the volumes
  again afterwards instead of inferred from `tmutil`'s exit status.

- `linux/systemd/stay_fresh_timer.sh --dry-run` documented a timer it could
  never install. The help said the flag made the timer invoke `stay_fresh.sh`
  with `--dry-run`, and the code built an `ExecStart` for it, but the install
  preview returns before any unit is written, so no unit ever carried it — a
  timer that previewed maintenance forever and did none was never a thing this
  script could produce. The dead branch is gone and the help describes what the
  flag does: preview the install, write nothing.
- `linux/systemd/stay_fresh_timer.sh` checks options against the command they
  follow. Every flag was accepted after every command, so `uninstall --hour 3`
  looked like it had rescheduled something and had not, while
  `uninstall --dry-run` read as a preview and disabled the timer and deleted
  both unit files for real. A command handed an option it cannot act on now
  exits 3, the way `macos-initial-setup/launchd/stay_fresh_agent.sh` already
  did.

- `stay_fresh.sh` invented a reclaimed total when `df` could not answer. The
  reading after the run discarded its failure status, so a working `df` before
  and a failing one after made the total the negative of the whole disk — and
  that figure travelled into the summary, `last-run.json`, `history.tsv` and
  every `--trend` average computed from them. An unmeasured run now says so and
  records nothing; the per-step total, which is counted rather than subtracted,
  is unaffected.
- `stay_fresh.sh` announced local snapshots "thinned" when every
  `tmutil deletelocalsnapshots` had failed: the flag behind the verdict and the
  notification was set before the deletion loop rather than from what it
  achieved. A run that deletes nothing now reports the snapshots kept, with each
  failure named.

- Every suite that syntax-checks its package now does so with `"$BASH"`, the
  interpreter running the suite, rather than a bare `bash` resolved through
  `PATH`. On `macos-15` those differ: CI starts the suite with `/bin/bash`,
  the Apple 3.2 that is the point of that job, while `PATH` there puts
  Homebrew's Bash 5 ahead of `/bin`. #49 fixed the macOS suite; the k8s-toolbox
  suite had the same bug and does run on that runner (`run-tests.sh static
  k8s dotfiles`), so its `bash -n` was asking Bash 5 too. The git, linux and
  windows suites are changed for the same rule, though they run only where the
  two interpreters coincide. `check_conventions.sh` now enforces it across
  every suite: the probe that proves the pattern still matches the bare form
  and leaves `"$BASH"`, `"${BASH:-bash}"`, an absolute path and a printed
  `ok "bash -n …"` label alone is itself a floor, and zero suites scanned
  fails.

- The test suites no longer inherit the variables the scripts they run read
  from the environment — `XDG_CACHE_HOME`, `BUN_INSTALL`,
  `TF_PLUGIN_CACHE_DIR`, `UV_CACHE_DIR`, `STAY_FRESH_LOCK_DIR` and the
  notifier tokens among them. Inherited, they aim a run at a real cache or a
  real webhook instead of the fixture: one exported `BUN_INSTALL` satisfied a
  relocation assertion from `~/.bun`, passing locally and failing in CI. A
  static check now derives the set from the scripts themselves, so the next
  such variable is covered by the commit that reads it.
- Two `BUN_INSTALL` assignments in the macOS steps suite were written as
  `VAR=x out="$(...)"`, which is two shell assignments rather than a command
  prefix: the value outlived its test and pointed every later run at a
  deleted fixture.

- `linux/system_doctor.sh` swallowed the hint beside its pending-upgrade count.
  `info()` rendered only its first argument, so the preview command passed as a
  second one went nowhere — the single observation that offers you a next
  command without being a finding was the single one that could not show it.
  `info()` now takes the same optional dimmed second line `warn()` has, and
  `--quiet` still suppresses both.

- The macOS steps suite forwarded only a named list of variables to
  `stay_fresh.sh`, and the cache-location ones were not on it. `BUN_INSTALL`
  is exported on a developer machine and in the suite's own container, so a
  test meant to exercise the default cache path cleared the real one instead
  and passed for the wrong reason; a caller writing `FOO=x out="$(run_sf …)"`
  was also making two assignments rather than prefixing a command, so the
  value never reached the script at all. `BUN_INSTALL`, `TF_PLUGIN_CACHE_DIR`,
  `CLOUDSDK_CONFIG` and `UV_CACHE_DIR` are now forwarded explicitly, which
  both carries a test's value in and keeps the host's out.

- `test-env/static/test_changelog.sh` used GNU-only `find -printf` with no
  fallback, so on macOS its three "writes nothing" assertions compared two
  empty strings and passed vacuously, and two bare `sed -i` calls failed
  outright there. The one real invocation in `linux/tests/`'s new block was
  not bracketed with `set +e`, which made its assertion unfailable and would
  have taken the forty assertions after it down with the suite.

- `mikrotik/core/tg_send.lua` reads `:global TgBotToken` / `TgChatId` instead of
  `TG_BOT_TOKEN` / `TG_CHAT_ID`, so it runs on RouterOS 7.24, which refuses to
  execute a script declaring an underscored name. This is a breaking change for
  a router already sending notifications, and the old values are not
  recoverable on 7.24: globals are runtime state repopulated at boot, and the
  startup script that set them cannot run there, so `/system script
  environment` has nothing to copy. Re-enter the token and rewrite the startup
  script. Migrating on 7.23 first is easier, but the snippet alone lasts only
  until the next reboot — the startup script has to change too.
  `router_doctor.py` reports `TgBotToken is not set` until it does. Note the
  scope: `tg_send` now runs on 7.24 for the three scripts that also run there;
  the sixteen other notifying callers still declare underscored globals.

- `v1_stay_fresh.sh` no longer runs its fixed cleanup on a bare invocation.
  That path deleted Xcode Archives, emptied `brew --cache` and sent
  `killall Finder` with no dry-run and no skip flags. A bare run now
  prints the deprecation and exits 3. `--legacy-run` is the opt-in that
  keeps the old sequence for the machines that still want it.

- `windows/tests/contract.ps1` counts exit `3` from a dry run as a failure
  instead of a pass. Exit 3 is this repository's usage error, so a run that
  ends in it was rejected during argument parsing and stopped before the code
  that could write was reached — "wrote nothing" is true and meaningless, the
  same reasoning `test-env/static/check_conventions.sh` has always applied on
  the Bash side. It mattered because `Get-DryRunArgument` hardcodes the verb
  each script needs to reach its preview: `import` for `winget_bootstrap.ps1`,
  `install` for `choco_bootstrap.ps1`, `apply` for `winget_configure.ps1`.
  Renaming any of those would have exited 3 at parameter binding and the suite
  would have reported `[ ok ] ... wrote nothing (exit 3)`, retiring that
  script's dry-run coverage without saying so. The failure now names the fix:
  add an entry to `Get-DryRunArgument`. The verdict was lifted out of the loop
  into `Get-DryRunVerdict` so the suite's own judgement is covered by tests
  rather than being the one thing in the file nothing checks.

- `lib/workspace_scan.py` aborted the whole scan with a traceback on a
  workspace path containing a NUL byte: `os.lstat()` raises `ValueError`,
  which is not an `OSError`, and nothing caught it. One unparsable manifest
  left every entry for every editor unclassified. Such a path is now
  `unresolved`, like any other it cannot reach.

- `stay_fresh.sh` refuses to run without a usable `HOME` instead of
  addressing the machine. Every path it clears is built from `HOME`, and an
  empty one made `"$HOME/Library/Caches"` into `/Library/Caches`, the system
  cache directory, and `"$HOME/.Trash"` into `/.Trash`; unset, `set -u`
  aborted with a bare "HOME: unbound variable" before `--help` could answer.
  `--help`, `--list-steps` and the flag validation the agent uses still work
  without one; anything that resolves a path stops with exit 2 and says why,
  and `HOME` is poisoned with a path that cannot exist until that check runs,
  so nothing can reach a system directory in the meantime.
- The Trash step leaves the per-volume Trash alone when the uid cannot be
  read, instead of sweeping `.Trashes/` — the shared parent that holds every
  user's trash on that volume. `~/.Trash` needs no uid and is still emptied.
- A `df` that cannot be read is reported once and counted as zero, rather
  than passing the empty string into every later size calculation and the
  history row.
- `stay_fresh.sh` runs on a full disk. TMPDIR lives on the disk the script
  is run to free, and three things there used to stop it: the log could
  not be opened, so the run refused to start with exit 2; `mktemp` failed,
  so a cache sweep that could not open its error file ran nothing at all;
  and the lists the sweeps build before deleting had nowhere to go. The log
  and the scratch lists now fall back to `~/Library/Logs/stay_fresh`, and
  failing that the run proceeds without a log and says so; `rm`'s errors
  are captured in memory rather than in a file; a step that has no scratch
  space anywhere skips its sweep with a warning instead of a shell error.
- `stay_fresh.sh`'s notifiers are under a limit of their own
  (`STAY_FRESH_NOTIFY_TIMEOUT`, 20 seconds): a locked keychain, or a
  Keychain item whose access list does not include `security`, raises a
  prompt nobody at a scheduled run can answer, and the lookup held the run
  open indefinitely after the work was done and before the verdict. A
  timed-out lookup is named; `osascript` and `curl` are bounded the same
  way.
- `stay_fresh.sh` says before the run when perl is missing and
  `--step-timeout` therefore cannot be enforced, instead of running every
  command unbounded in silence.
- `stay_fresh.sh` retries a "Permission denied" cache entry with sudo by
  naming exactly the top-level entries `rm` refused, instead of re-running
  `find -exec rm` over the whole directory as root. The sweep also reached
  for the entries macOS keeps out of reach on purpose (HomeKit, CloudKit,
  Safari), which the first pass had correctly counted as protected and kept.
  Both the macOS (`rm: /p: Permission denied`) and GNU
  (`rm: cannot remove '/p': Permission denied`) forms are parsed, the retry
  is announced with its count, and the unprivileged suite runs it as uid
  1000 against a directory the kernel really refuses.
- `stay_fresh.sh` aborts on Ctrl-C again. The `--step-timeout` wrapper
  caught the interrupt, stopped the command and exited 130 normally, which
  bash reads as "the child handled it": the interrupted command was booked
  a warning and the run went on to the next step, one Ctrl-C per command.
  The wrapper now dies of the interrupt itself after stopping the command,
  so bash ends the run and the lock is released. At a terminal it also
  signals the command's children, found through `pgrep -P` before the
  parent goes, so a `git fetch` brew left behind cannot keep the log pipe
  open past the limit; and a command run through `sudo` is stopped through
  `sudo -n kill`, since root's process refuses an unprivileged signal and
  the wrapper then waited for it to finish and reported a timeout for work
  that completed.
- `stay_fresh.sh` bounds the probes that used to run outside the timeout:
  `docker info` at preflight and in the step, `docker system df`, `gcloud
  components list` and `gcloud version` (with its update check disabled). A
  daemon that accepts the socket and never answers hung the run with the
  lock held, which is the failure `--step-timeout` was added for. A probe
  stopped by the limit now counts as a step warning too, as the help always
  said; `capture_cmd` reported the stop and then booked the step `[ ok ]`,
  so the agent's `--fail-on-warn` never saw it.
- `STAY_FRESH_STEP_TIMEOUT` is validated like `--step-timeout`: `30m`
  became a 30-second limit through perl's numification and `abc` silently
  disabled the limit; both now exit 3 with the value named.
- `stay_fresh.sh`'s `user-logs` step keeps its file list out of the argument
  vector: the machine it exists for carries tens of thousands of eligible
  files, more than ARG_MAX holds, and `du`/`rm` on the whole list failed
  with nothing removed. The NUL-separated list stays in a file and `xargs`
  batches every pass. A directory `find` could not enter no longer discards
  the scan either: what was listed is removed and the directory is named
  as a warning.
- The Trash step reads the volume list from the mount table before touching
  anything under `/Volumes`. The glob it used stats every entry, and stat on
  the mount point of a share whose server went away blocks in the kernel
  before the network-share check could run, which is the hang the check was
  added to prevent. Volume names with spaces and parentheses are parsed
  whole, and a directory under `/Volumes` that is not a mount is ignored.
- The run lock's boot-time check tolerates five minutes of drift. XNU
  re-derives `kern.boottime` whenever the clock is stepped, which NTP and
  sleep/wake do by seconds, and a lock held by a live run was discarded as
  pre-reboot on the next scheduled firing, letting two runs upgrade and sweep
  at once.
- The narrowed sudo retry no longer counts BSD rm's "Directory not empty"
  lines, printed for each parent of a refused file, as leftovers after the
  retry removed that entry; on a real Mac every retry that worked ended the
  step as a warning.
- `stay_fresh_agent.sh install --notify` asks `stay_fresh.sh --list-steps
  --notify VALUE` whether the value is acceptable instead of keeping its own
  copy of the grammar, which had already drifted: `none,macos` passed the
  install check and failed every scheduled run with exit 3 and nothing
  watching. `--list-steps` now answers after the argument checks for exactly
  this.
- `stay_fresh_agent.sh status` measures staleness from the run the schedule
  itself fired, stamped in `last-scheduled` by `run-scheduled`, or from the
  plist's modification time when it has never fired, instead of from
  `last-run.json`, which every manual run rewrites: a `stay-fresh --quick`
  by hand every few days hid a job that had not fired for months, and an
  old manual run flagged a job installed two days ago.
- `stay_fresh.sh --thin-snapshots` no longer deletes local snapshots while a
  Time Machine backup is running (`tmutil status` reports `Running = 1`).
  A backup copies from the newest snapshot, and deleting it underneath made
  the pass start over; the snapshots are listed, the verdict says "kept",
  and the next run thins.
- `stay_fresh.sh` no longer leaves an empty log in `TMPDIR` after a clean
  run that notified. The clean run's log was discarded before the
  notification went out, and both notifiers logged into the same path, so
  the append recreated the file: one orphan per scheduled run, the exact
  promise `CONTRIBUTING.md` makes about a run's own files. The discard now
  comes last; a kept log receives the notifiers' output instead.
- A notification that cannot be sent is said on the terminal with curl's or
  osascript's reason, the bot token scrubbed. A wrong chat id or a blocked
  network used to vanish into that discarded log.
- The Homebrew log mark counted non-empty lines with `grep -c .` and then
  read with `tail -n +N`, which counts every line, so the reads started
  inside an earlier step by as many blank lines as docker and the cache
  sweeps had written. `wc -l` on both sides.
- The trash step skips network shares. `find` on an SMB, NFS, AFP or WebDAV
  volume whose server went away blocks for as long as the kernel retries,
  and on a scheduled run nobody is there to interrupt it. The mount type
  comes from `mount(8)` without touching the volume; the share is named and
  left to Finder.
- The run lock records the boot it was taken in. After a reboot an unrelated
  process can wear the old pid, and `kill -0` then reported a run that ended
  with the power as active, for as long as that process lived. A lock from
  an earlier boot is now removed as stale whatever its pid says.
- `--quick` never uses sudo, as its help says: the retry for cache entries
  owned by another user used a credential another shell had left warm.

- `linux/stay_fresh.sh` empties the whole Trash. It cleared
  `~/.local/share/Trash/files` and left the matching `info/` records, so the
  desktop kept showing entries whose files were gone; `disk_cleanup.sh` in
  the same directory has always cleared both.
- `linux/stay_fresh.sh` refuses an unset, empty or non-directory `HOME` with
  exit 2. `rm -rf "$HOME/.cache/pip"` with an empty `HOME` addresses
  `/.cache/pip`, and `set -u` does not fire on a variable that is set but
  empty. `--help` and `--list-steps` still work without one.
- `linux/stay_fresh.sh` discards a clean run's log instead of leaving one
  file per run in `TMPDIR` forever; a run with a failed step keeps its log
  and prunes to the ten newest.
- `linux/stay_fresh.sh`'s `warn()` prints the fix hint its callers pass as a
  second argument on its own dimmed line, as `system_doctor.sh` does. With a
  `"$*"` body the hint was glued onto the end of the message, so the
  stale-library warning ran the hint on as part of the same sentence.
- `linux/stay_fresh.sh` names flatpak and snap among the steps it skipped
  under `--only`, which it already did for every other step.
- `stay_fresh.sh` tells the macOS protections apart from failures. A real run
  warned on three steps for things no run can change: `/System/Library/Caches`
  answers "Operation not permitted" to root with System Integrity Protection
  on, `/Library/Caches` and `~/Library/Caches` hold a dozen Apple entries the
  privacy controls keep out of reach (HomeKit, CloudKit, Safari, `aned`), and
  `~/.Trash` cannot even be listed by a terminal without Full Disk Access.
  Every run warned, and a warning that fires every run is the one that gets
  muted. Now `/System/Library/Caches` is left alone while SIP is on, protected
  entries are counted and kept without a warning, and the Trash is emptied
  through Finder in an interactive run or the missing grant is named in a
  scheduled one. An entry owned by another user - the root-owned directory
  Slack's updater leaves in the caches - is the fixable case and is treated
  as such: retried with sudo when a credential is already in hand, warned
  about when not.
- `stay_fresh.sh` no longer reports `brew update` clean when a stale git lock
  stopped it: Homebrew prints "Unable to create '.../.git/index.lock'", then
  "Already up-to-date", and exits 0 with the taps untouched, so the upgrade
  that followed ran on the previous index and the summary said nothing. A
  lock older than five minutes with no git process running is removed and
  said so; any other lock is named with the remedy, and the update that
  could not refresh the taps is counted as a warning. Casks and formulae
  Homebrew has disabled, which it says once per upgrade in a line nobody
  reads, are named with their reason. npm's own "using --force" notice stays
  out of the quiet stream, and an aborted run no longer leaves an empty log.
- `stay_fresh.sh` dev-caches also clears Terraform's provider plugin cache
  where one is configured, removes gcloud log directories older than a week
  (one per invocation, never pruned by gcloud, hundreds of megabytes on a
  machine that scripts it), and runs `pre-commit gc`.
- A literal `%` in Telegram message text is now sent as `%25`, in
  `health_check.lua`, `latency_monitor.lua` and `traffic_quota.lua`. `tg_send`
  posts the text as `application/x-www-form-urlencoded`, which is why newlines
  are written `%0A` — and by the same rule a bare `%` is a truncated escape
  sequence. It has been getting through on decoder leniency rather than on
  being correct, and it stops being cosmetic the moment the two characters
  after it are hex digits, which silently yields a byte instead of a percent
  sign.

- `update_check.lua` waits for the update check to finish by polling `status`
  until it reaches a verdict, instead of by waiting a fixed 10 seconds.
  RouterOS keeps `latest-version` from the previous check, so testing that
  field for content answers "has this router ever checked", not "has this
  check finished" — a distinction that only shows up as a stale verdict, never
  as an error.

- `update_check.lua` escapes the router identity before interpolating it into
  the message. It is operator-supplied text going into a URL-encoded body that
  Telegram then parses as HTML: an `&` in an identity ends the text field early
  and silently truncates the rest of the message, and a `<` opens a tag
  Telegram cannot close and the send is rejected outright. The same exposure
  exists wherever the other scripts interpolate an identity or a rule comment,
  and is not addressed here.

- `linux/packages.sh install --dry-run` mixed three output forms on one preview
  path, including `git/`'s `dry-run: would run:`, and its command-preview
  `printf` omitted the trailing newline so `dry-run complete; no changes written`
  was glued onto the same line. Install now matches the linux indented
  `(dry-run)` grammar already used by `dump` in the same file (and by
  `stay_fresh.sh` / `sysctl_defaults.sh`): dimmed two-space previews, every
  line ending in a newline, then the standalone closing summary. The suite
  asserts the closing line, the indented form, and the absence of the git
  mix.

- `launchd/stay_fresh_agent.sh` rejected `--weekday=`, `--hour=`, `--minute=`
  and `--profile=` as unknown arguments, and `stay_fresh.sh` did the same for
  `--prune-xcode-archives-days=`. The equals form is half of the documented
  argument contract, and the divergence ran along the platform seam: the agent
  already took `--tail=80`, and `linux/systemd/stay_fresh_timer.sh` took the
  equals form for all four of its own flags, so the same flag on the same
  conceptual tool behaved differently depending on the machine. Both forms now
  produce a byte-identical plist, and an invalid value still exits `3`.

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
- `stay_fresh.sh` cleared `/System/Library/Caches` whenever it could not prove
  SIP was on: the probe read `csrutil status` and treated a missing binary, a
  non-zero exit and an unrecognised (localised) answer alike as "off". On a
  machine where SIP genuinely is off that swept the dyld and kernel caches,
  which is minutes of rebuild and an alarming first boot for a few megabytes.
  The probe now answers `enabled`, `disabled` or `unknown`, only a positive
  `disabled` counts, the step is additionally gated behind the new
  `--force-system-caches`, and `com.apple.dyld`, `com.apple.kernelcaches` and
  `com.apple.bootstamps` are excluded even then.
- The per-app cache step decided an application was idle from `pgrep -x` on a
  process name. Electron applications run as `Electron`, `Code Helper` or a
  renderer, never as `Visual Studio Code`, so an open editor read as idle and
  had its cache cleared underneath it. The check now matches the bundle
  executable path (`/Visual Studio Code.app/Contents/MacOS/`) with `pgrep -f`.
- `lib/workspace_scan.py` classed a workspace as stale whenever `lstat` said
  the folder was not there, which is also what an unmounted external volume
  and an iCloud Drive file the provider has not materialised say. Unplugging
  a disk before a run therefore deleted that project's editor state. Those two
  cases are now `unresolved` and kept, and a real `ENOENT` on a mounted volume
  remains stale.
- The Docker step ran a bare `docker container prune -f`, which also removes
  the container you stopped minutes ago and meant to restart. It now filters
  on `until=168h`, so only containers stopped for more than a week go.
- `simctl delete unavailable` ran unconditionally. A half-finished Xcode
  update marks every simulator unavailable, and the command deletes their app
  data, databases and screenshots with them. It now needs
  `--prune-unavailable-simulators`; otherwise the count is reported.
- The developer-cache step cleared whatever `TF_PLUGIN_CACHE_DIR` pointed at.
  A variable exported to a working directory — or to an empty value, which
  resolves to `$HOME` — meant that directory was emptied. The path must now
  end in `plugin-cache`; anything else warns and is left alone.
- `clear_dir()` accepted an empty or relative argument and would have swept
  the process's working directory. It now refuses anything that is not an
  absolute path below `/`.
- The kept log recorded the commands a run executed but not its `[warn]` and
  `[err ]` lines, which are the reason the log was kept in the first place.
  Both now go to the log, timestamped. The sink stays `/dev/null` until
  preflight passes, so a refused run still writes nothing.

### Security

- Every binary CI downloads is now checked against the SHA-256 recorded in
  `.github/ci-tool-checksums.env` before it is unpacked or installed, and the
  step fails on a mismatch. That file declared itself the source of truth for
  these digests and warned in its own header that a version pin without a digest
  still trusts whoever answers the URL — while nothing in the tree read it. A
  search for its name returned the file and nothing else, so ShellCheck,
  actionlint, Hadolint, kubeconform and ruff were each installed on a version
  pin alone, and the two Darwin digests recorded for the `macos-native` job had
  never once been compared against anything. The Ubuntu jobs verify with
  `sha256sum -c` and the macOS job with `shasum -a 256 -c`, since GNU coreutils
  is not part of the macOS base system; the macOS step selects its digest by
  runner architecture alongside the asset, so the two cannot disagree.
- `test-env/static/check_conventions.sh` asserts that the `env:` block of
  `.github/workflows/ci.yml` and `.github/ci-tool-checksums.env` name the same
  tools at the same versions, and that every digest recorded there is named by a
  step in the workflow. A bump that edited a version in one file and forgot the
  other used to be invisible in review and silent until a job installed the
  tool; it now fails the static suite naming both values. yamllint and
  PSScriptAnalyzer arrive through pipx and Install-Module rather than as release
  downloads, and are declared as such in the digest file itself rather than
  exempted inside the test.

- `linux/config_backup.sh` created its archive at whatever umask it inherited,
  which under a stock 022 meant mode 0644. The default `--paths` is `/etc` and
  the script plainly expects a privileged run — it treats tar's exit 1 as
  "unreadable files under /etc, archive still written" — so `sudo
  ./config_backup.sh --yes` left shadow, the sshd host keys and sudoers in a
  tarball under a predictable name that every local account could read. The
  archive is now created 0600. `--dest` keeps the mode the operator gave it:
  the secret is the file, not the folder.

- `.github/dependabot.yml` now sets `cooldown: default-days: 7` on both the
  `github-actions` and `docker` ecosystems. Every action here is already
  pinned to a commit SHA and every base image to a version tag, watched by
  Dependabot rather than left to rot — but a same-day bump still adopts a
  release before anyone has had a chance to notice it was compromised. A
  seven-day wait does not weaken the pin, it delays what replaces it.
  `default-days` is the only cooldown key set here — the `semver-*-days`
  variants are documented as applying only to package managers that support
  SemVer, and neither github-actions nor docker resolves its version that
  way (actions read a ref, docker reads a tag), so those keys are left
  unset rather than added on an unconfirmed guess at what setting them
  would do.

- `stay_fresh_agent.sh` escapes `--profile`, `--notify` and `--notify-when`
  before they reach the LaunchAgent plist, as it already did for the script
  and log paths two lines below. No value can reach that plist unescaped
  today — each is rejected by an exact-match validator first, which a security
  review confirmed by injection — so this makes the writer correct on its own
  rather than only because a validator elsewhere happens to be strict.

- `routeros_version.py record-hash` hashed whatever arrived, so the digest
  that pins the CHR image described a truncated download as confidently as a
  complete one. `http.client` returns an empty read and closes the connection
  when a `Content-Length` body is cut short rather than raising — the standard
  library documents the choice in a comment — so the chunk loop read a partial
  body to what looked like the end of the file. Two scheduled release checks
  recorded two different digests for the same `chr-7.24.4.vdi.zip` four days
  apart, and both were rejected by the image build's own `sha256sum -c`; that
  rejection is the only reason this was ever visible. The transfer is now
  measured against the length the server announced, a body with neither a
  length nor chunk framing is refused because its end cannot be told from a
  dropped connection, and a complete body that is HTML or far too small to be
  an archive is refused as well — an error page served under a 200 is whole by
  every framing test and would otherwise be pinned as though it were the
  image. Each host is retried the way the Dockerfile's `wget --tries=3`
  already does before the next mirror is tried, and the host and byte count
  are reported on stderr, leaving stdout to carry the digest alone.

- `routeros_version.py record-hash` now refuses a body that does not open with
  a ZIP signature. The checks that stood between an error page and the CHR
  pin read only what the server said about the body — a `text/*` type and a
  size floor — so an `application/xml` error page from a CDN, or the wrong
  object, of any size above the floor would have been hashed and pinned as
  though it were the image. The type and a declared length below the floor are
  now judged from the headers before the body is read, so a mirror answering
  with a page no longer costs a download the size of the image on every
  attempt.

- `.github/workflows/routeros-version.yml` declared `actions: write`,
  `contents: write` and `pull-requests: write` at the workflow's top level,
  where every job in the file inherits them — and this is the one workflow
  here that can push a commit and open a pull request. The scopes are genuinely
  needed by `check-test-and-propose`, so they moved to that job instead of
  being removed; the top level is now `permissions: {}`. A job added to this
  workflow later starts with no access rather than three write scopes nobody
  granted it on purpose.

- Added `.github/workflows/security.yml`. Nothing before it scanned this
  repository for a committed credential, a workflow that lets untrusted input
  reach a `run:` block, or a dependency pulled in the day it was published —
  `ci.yml`'s `Lint` job checks that a script or workflow is well formed, not
  that it is safe. The new workflow scans the working tree for secrets with
  Trivy and gates on a hit, scans git history for secrets with gitleaks
  (`--no-color`, its stderr-only summary line captured too) and reports
  rather than gates (a history finding needs a rewrite plus rotation, not a
  blocked pull request; the two fixture matches already in history are
  suppressed via `.gitleaksignore`), audits the workflows with zizmor —
  online, via `GH_TOKEN`, so its token-gated audits such as
  `impostor-commit` actually run, and a failure to run zizmor at all now
  fails the job instead of a swallowed `|| true` — runs CodeQL over the
  `actions` and `python` languages (Go and Ruby are also CodeQL-supported
  here, but exist only as `test-env/` fixtures and are left out on
  purpose), and runs OpenSSF Scorecard against `master` only, on a
  schedule — gated on `github.ref` as well as the event, since
  `workflow_dispatch` from any other branch is a scan Scorecard itself
  refuses to run. SARIF from every tool lands in the Security tab.

- `status.sh` and `workstation_doctor.sh` reported System Integrity Protection
  as enabled on a machine where it was partially disabled. `csrutil status`
  answers `status: unknown (Custom Configuration)` when individual protections
  are turned off and then lists them — and that list contains
  `Kext Signing: enabled`. Both readers matched a bare `enabled` anywhere in
  the block, found that line, and called the machine green. `status.sh` went
  further and exited 0, so its security section passed a Mac with filesystem
  protections off. Both now anchor on the `status:` prefix, as `stay_fresh.sh`'s
  `sip_status()` and `hardening_audit.sh` already did — the comment in
  `sip_status()` names this exact failure ("on a machine with a custom
  configuration it answers 'unknown'. All of those used to read as 'SIP is
  off'"), so two of the four copies were hardened and two were not. A custom
  configuration is now reported as partially disabled, which is a warning in
  both scripts. `workstation_doctor.sh` also reads `csrutil status` once
  instead of up to three times.

- Telegram notifications put the chat id on the `curl` command line
  (`--data-urlencode chat_id=...`). The bot token already rode in a stdin
  config so `ps` could not read it; the chat id did not. It goes in the same
  config now.

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
