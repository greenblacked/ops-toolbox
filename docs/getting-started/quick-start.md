# Quick start

<!-- markdownlint-disable MD033 MD046 -->

This page gets you from nothing to a first report on your platform. Nothing
here installs software or changes settings.

## 1. Get the code

**Requires:** Git and a shell. Cloning writes a new local folder; it does not
modify system settings. To undo just the clone, remove that folder only after
checking that you have no work in it.

```bash
git clone https://github.com/greenblacked/ops-toolbox.git
cd ops-toolbox
```

All commands in these docs run from the repository root unless stated
otherwise.

## 2. Run a report

<span class="stage stage-report">Read-only</span> **Requires:** the selected
platform's shell and any tool documented by that script. **Changes:** none
for the example commands below. **Rollback:** not needed.

Reports are read-only. Pick the one for your platform. On your first visit
from a computer, the tab for its operating system (macOS, Linux or Windows)
opens by itself; pick another and the site remembers that instead.

=== "macOS"

    ```bash
    ./macos-initial-setup/status.sh
    ```

=== "Linux"

    ```bash
    ./linux/status.sh
    ```

=== "Windows"

    ```powershell
    .\windows\setup\status.ps1
    ```

=== "Git"

    ```bash
    ./git/git_whoami.sh
    ```

=== "Kubernetes"

    ```bash
    ./k8s-toolbox/build.sh --dry-run
    ```

=== "Dotfiles"

    ```bash
    ./dotfiles/install_dotfiles.sh --list
    ```

=== "MikroTik"

    ```bash
    ./mikrotik/features/print_schedulers.sh
    ```

    !!! report "Read-only"
        This prints scheduler commands to review. It contacts no router.

## 3. Preview a change

<span class="stage stage-preview">Dry run</span> **Requires:** the script and
its host-platform dependencies. **Changes:** no system settings for the
commands below, but some probes can still read external state. **Rollback:**
not needed. Dry-run coverage varies by script.

Every script that writes has its own preview. For example:

```bash
./linux/stay_fresh.sh --dry-run
./macos-initial-setup/install_apps.sh --dry-run
./git/git_sync_default.sh --dry-run
```

```powershell
.\windows\setup\stay_fresh.ps1 -DryRun
```

!!! preview "A preview has its own scope"
    Each script's `--dry-run` covers what that script says it covers. Read
    its `--help` output and the platform page before you rely on it.

## 4. Apply

<span class="stage stage-apply">Changes state</span> An apply may install
packages, change configuration or delete files depending on the script.
Only run it after reviewing its exact effects and recovery steps.

For a concrete reversible macOS example, from `macos-initial-setup/`:

```bash
./macos_defaults.sh --apply --dry-run
./macos_defaults.sh --apply
```

If you need to restore the previous settings later, run this separately:

```bash
./macos_defaults.sh --revert
```

**Requires:** macOS and a completed preview. **Changes:** user defaults;
the script saves previous values. **Rollback:** `--revert`. Other scripts
may have no automatic rollback, so check their full guide rather than
assuming this pattern applies everywhere.

Before you apply:

- [ ] I read the report output
- [ ] I ran the preview and read every line
- [ ] I know how to undo it (the script can revert its change, or I have a backup)

Ticks are kept in this browser only, for this page, so a reload does not
lose your place. Nothing is shared or synced; **Reset checklist** clears
them.

## Next

Need a particular tool rather than a platform walkthrough? Use the
[search on the homepage](../index.md) or the
[full script inventory](../scripts/index.md).

- [Philosophy](philosophy.md) explains the report, preview, apply model.
- [Installation and usage](usage.md) covers working from a clone and copying scripts into `~/bin`, including the few that need their package folder.
- The [script overview](../scripts/index.md) lists every main script.

<!-- markdownlint-enable MD033 MD046 -->
