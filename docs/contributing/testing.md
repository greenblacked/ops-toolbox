# Testing

`./run-tests.sh` at the repository root is the single entry point. CI calls the
same script, so a local pass and a CI pass mean the same thing, on the tools and
platforms present on your machine.

```bash
./run-tests.sh --help       # suites and their requirements
./run-tests.sh --list       # the suite inventory CI reads
./run-tests.sh              # the default selection
./run-tests.sh all          # also the MikroTik CHR suite
./run-tests.sh git linux    # an explicit subset
```

## Suites

| Suite | Needs | What it checks |
| --- | --- | --- |
| `git` | Docker | ShellCheck, `bash -n`, `--help`, integration tests for the Git helpers. |
| `macos` | Docker with Compose v2 | Static checks, `--help`, exit codes, and `stay_fresh.sh` with host commands faked. Cannot run Homebrew. |
| `linux` | Docker | Scripts run for real in Debian; `LINUX_DISTROS=all` adds Fedora and Arch. |
| `k8s` | Bash only | Script contracts with stubbed `kubectl`; `K8S_IMAGE_SMOKE=1` builds the image. |
| `dotfiles` | Bash and git | The installer against a scratch home directory. |
| `python` | Host `python3` | Standard library `unittest`, plus `ruff` if installed. |
| `static` | Bash and git | Repo-wide conventions, pin age, doc citations. No network. |
| `lint` | Pinned linters | The linters CI's Lint job runs. `LINT_FETCH=1` downloads pinned binaries. |
| `windows` | `pwsh` | PowerShell contract checks; skipped without `pwsh`. |
| `mikrotik` | Docker, QEMU | Boots RouterOS CHR 7.24.5 and runs every `.lua` over the API. Not in the default selection. |

!!! note "Documentation changes"
    A docs-only change runs the `static` and `lint` suites. The site itself
    is checked with `mkdocs build --strict`; see
    [Development](development.md#documentation-site).

## What CI covers

The workflows in `.github/workflows/`:

- `ci.yml` runs on pushes to `master` and on pull requests: change detection,
  Lint, schema validation, native macOS (`macos-15`) and Windows
  (`windows-2025` with `pwsh`) jobs, the Linux suite matrix, Python helpers
  and the conventions suite.
- `chr.yml` runs the RouterOS CHR integration nightly, on demand, and on
  pull requests that touch `mikrotik/`.
- `routeros-version.yml` tests a newer CHR before proposing a version bump.
- `k8s-image-smoke.yml` builds and probes the toolbox image weekly.
- `security.yml` reports repository and workflow security findings.
- `branch-name.yml` enforces branch naming on pull requests.
- `release.yml` is the release workflow.

In short, CI covers shell syntax and lint, `--help` and exit-code contracts,
dry-run behavior, Linux package tests in Debian, Fedora and Arch containers,
macOS native checks, Windows contracts, Python unit tests and RouterOS CHR
integration.

## What you must still verify yourself

!!! warning "Passing CI is not proof for your system"
    These are not exercised by CI. Test them on the target before relying on
    them.

- Every advertised OS release. Only the `macos-15` runner and the three Linux
  containers run.
- Windows PowerShell 5.1. CI runs PowerShell 7.
- Real Homebrew installs, cask upgrades, and macOS defaults protected by SIP
  or TCC.
- Real winget, Chocolatey, WSL, BitLocker and Defender behavior.
- Linux kernel and sysctl effects on real hardware.
- Real Kubernetes clusters. Tests use stubbed `kubectl` and never contact one.
- The OrbStack or Kali cloud-init path on a stock image.
- Real router behavior beyond the CHR image: Telegram delivery, address-list
  and firewall enforcement, and compatibility with your firmware.
- A cron job or systemd timer firing in a live session. Containers test only
  `--print-only`.

## Writing tests

Every package has a `tests/run.sh` that takes no required arguments and exits
non-zero on failure. Test bodies are hand-rolled Bash harnesses; see
`git/tests/test_git_scripts.sh` in the repository for the shape. Docker suites
mount the repository read-only, so scratch state goes under `/tmp`.
