---
hide:
  - toc
---

<!-- markdownlint-disable MD033 -->
<!-- markdownlint-disable-next-line MD026 -->
# Scripts that show you before they change anything. { .rpt-title }

<div class="rpt-hero" markdown>

<p class="rpt-lede">Standalone helper scripts for maintaining workstations,
servers, Git repositories, MikroTik RouterOS devices and GKE clusters.</p>

[Quick start](getting-started/quick-start.md){ .md-button .md-button--primary }
[View on GitHub](https://github.com/greenblacked/ops-toolbox){ .md-button }

</div>

Work from a clone or copy the script you need into `~/bin`, run its report,
preview what it would change, and only then apply. Here is that order with one
real script, `macos_defaults.sh`, run from inside the `macos-initial-setup`
folder:

<div class="rpt-stages" markdown>

<div class="rpt-stage rpt-stage--report" markdown>
<span class="stage stage-report">1 · Report · read-only</span>

Prints the current value of each setting beside the desired one. With no
flags it changes nothing.

```bash
./macos_defaults.sh
```

</div>

<div class="rpt-stage rpt-stage--preview" markdown>
<span class="stage stage-preview">2 · Preview · dry run</span>

Shows the commands `--apply` would run, without running them.

```bash
./macos_defaults.sh --apply --dry-run
```

</div>

<div class="rpt-stage rpt-stage--apply" markdown>
<span class="stage stage-apply">3 · Apply · changes things</span>

Writes the desired values, after saving the previous ones to a backup file
that `--revert` can restore.

```bash
./macos_defaults.sh --apply
```

</div>

</div>

## Platforms

<div class="grid cards" markdown>

- **[macOS](platforms/macos.md)**

    ---

    macOS 12+ setup, maintenance, reports and preferences.

- **[Linux](platforms/linux.md)**

    ---

    Debian/Ubuntu, Fedora/RHEL and Arch reports, maintenance and cleanup.

- **[Windows](platforms/windows.md)**

    ---

    PowerShell 5.1 or 7 scripts, WSL management and Git Bash dotfiles.

- **[Git](platforms/git.md)**

    ---

    Identity, repository reports, sync and branch cleanup helpers, hooks.

- **[MikroTik](platforms/mikrotik.md)**

    ---

    RouterOS 7.x scripts for backups, watchdogs and alerts, plus host tools.

- **[Kubernetes](platforms/kubernetes.md)**

    ---

    A GKE-oriented CLI image, triage and cluster doctor scripts.

- **[Dotfiles](platforms/dotfiles.md)**

    ---

    Tool configuration with a per-file link or copy installer.

</div>
## Principles

<div class="grid cards cols-2" markdown>

- **Safety and predictability**

    ---

    Work moves from **report** to **preview** to **apply**. Reports read
    state. Previews (`--dry-run` or the platform's equivalent) print what a
    command would do. Applying is always a separate, explicit step.
    See [Philosophy](getting-started/philosophy.md).

- **Modularity**

    ---

    Most scripts are self-contained and still work when copied on their own
    into `~/bin`; a few need their package folder (see
    [Installation and usage](getting-started/usage.md)). Duplication between
    scripts is deliberate.

- **Minimal dependencies**

    ---

    Bash 3.2+ for the macOS, Linux, Git and dotfiles scripts (Git Bash
    scripts target Bash 5), PowerShell 5.1 or 7 for the Windows ones,
    and Python standard library only for the helpers. Docker is needed only
    for the test suites and the Kubernetes image.

- **Honest about testing**

    ---

    CI runs lint, contract checks and container tests. It does not run every
    OS release, real package managers on every platform, or real routers and
    clusters. Verify behavior on the target system. See
    [Testing](contributing/testing.md).

</div>
<!-- markdownlint-enable MD033 -->

## Quick start

Run these from a clone of the repository. The report reads the effective Git
identity and changes nothing.

```bash
git clone https://github.com/greenblacked/ops-toolbox.git
cd ops-toolbox
./git/git_whoami.sh
./k8s-toolbox/build.sh --dry-run
```

The second command prints the Docker buildx command it would run and builds
nothing. Pick your platform above for its own first report.

## Status

!!! note "A personal but public toolkit"
    This is one person's toolkit, published so others can read it and reuse
    single files. There is a single maintainer and no support commitment.
    The first tagged release is v0.1.0 (2026-10-10); `master` is
    what exists beyond it. The project is MIT licensed.

!!! warning "Test before you trust"
    Scripts that change a machine, repository, router or cluster are tested
    in containers and on CI runners, not on your system. Read the report and
    the preview, then apply.

This site is published at <https://ops.szolotov.com>. Its source is the `docs/`
folder and `mkdocs.yml` in the
[repository](https://github.com/greenblacked/ops-toolbox).
