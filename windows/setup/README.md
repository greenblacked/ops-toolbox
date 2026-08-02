# Windows setup

Capture what a Windows machine has installed, keep it under version control,
and reproduce it elsewhere.

| File | Purpose |
| --- | --- |
| [`winget_bootstrap.ps1`](winget_bootstrap.ps1) | `export` / `check` / `import` / `diff` over the winget package list |
| `winget-packages.json` | Written by `export`; commit it |

This is the Windows counterpart of
[`macos-initial-setup/brewfile.sh`](../../macos-initial-setup/brewfile.sh) — same
four verbs, same exit codes, same idea. A curated install list is the *intent*;
this file is the *fact*.

## Usage

```powershell
# What has changed on this machine since the file was written?
.\winget_bootstrap.ps1 diff

# Accept those changes
.\winget_bootstrap.ps1 export -Force

# On a new machine: preview, then install what is missing
.\winget_bootstrap.ps1 import -DryRun
.\winget_bootstrap.ps1 import

# Is everything in the file present? (read-only, exits 1 if not)
.\winget_bootstrap.ps1 check
```

`-File PATH` points any verb at a different file, so you can keep more than one
profile (a work machine and a personal one, say).

## Exit codes

Matching `brewfile.sh`, so either can be driven from the same automation:

| Code | Meaning |
| --- | --- |
| `0` | Success. For `check`: everything is installed. |
| `1` | The command failed. For `check`: something is missing. |
| `2` | Preflight failed — not Windows, or `winget` is not on `PATH`. |
| `3` | Bad arguments, or no verb given. |

## Things worth knowing

- **`export` refuses to overwrite** an existing file without `-Force`. Run
  `diff` first; that is the whole reason `diff` exists.
- **`import` uses `--no-upgrade`**, matching `brew bundle install --no-upgrade`:
  it adds what is missing and leaves what is already installed alone. It will
  not silently upgrade a pinned version.
- **Packages winget cannot identify are skipped.** Anything installed outside a
  winget source is recorded as `"unknown"` in the export and cannot be
  reinstalled from it. `export` prints how many fell into that bucket rather
  than letting you discover it on a rebuild.
- **`diff` compares sorted package ids, not raw JSON.** winget does not
  guarantee ordering between runs, so a raw file diff produces noise that is not
  really a change.

## Testing

`winget.exe` does not exist on Linux, so the CI suite cannot exercise the
behaviour of this script — only that it parses, that PSScriptAnalyzer is happy
with it, that its comment-based help is complete, that it offers `-DryRun`, and
that every flag documented above actually exists in its `param()` block. See
[`../tests/`](../tests/).

Behaviour has to be checked on a real Windows machine. `diff` and `check` are
read-only, so they are safe places to start.
