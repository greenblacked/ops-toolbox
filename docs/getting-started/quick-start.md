# Quick start

<!-- markdownlint-disable MD046 -->

This page gets you from nothing to a first report on your platform. Nothing
here installs software or changes settings.

## 1. Get the code

```bash
git clone https://github.com/greenblacked/ops-toolbox.git
cd ops-toolbox
```

All commands in these docs run from the repository root unless stated
otherwise.

## 2. Run a report

Reports are read-only. Pick the one for your platform.

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

    This prints scheduler commands to review. It contacts no router.

## 3. Preview a change

Every script that writes has its own preview. For example:

```bash
./linux/stay_fresh.sh --dry-run
./macos-initial-setup/install_apps.sh --dry-run
./git/git_sync_default.sh --dry-run
```

```powershell
.\windows\setup\stay_fresh.ps1 -DryRun
```

!!! warning "A preview has its own scope"
    Each script's `--dry-run` covers what that script says it covers. Read
    its `--help` output and the platform page before you rely on it.

## 4. Apply

Run the same command without the preview flag, or with the script's consent
flag (`--yes` for Bash, `-Yes` for PowerShell) where it asks for one.

## Next

- [Philosophy](philosophy.md) explains the report, preview, apply model.
- [Installation and usage](usage.md) covers working from a clone and copying scripts into `~/bin`, including the few that need their package folder.
- The [script overview](../scripts/index.md) lists every main script.
