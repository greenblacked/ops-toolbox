# Windows setup

Capture what a Windows machine has installed, keep it under version control,
reproduce it elsewhere — and then keep it healthy.

| File | Purpose |
| --- | --- |
| [`winget_bootstrap.ps1`](winget_bootstrap.ps1) | `export` / `list` / `check` / `import` / `diff` over the winget package list |
| [`winget_configure.ps1`](winget_configure.ps1) | `validate` / `show` / `test` / `apply` over [`configuration.winget`](configuration.winget), the curated machine definition |
| [`stay_fresh.ps1`](stay_fresh.ps1) | Recurring maintenance: winget upgrades, `wsl --update`, pending-reboot report |
| [`workstation_doctor.ps1`](workstation_doctor.ps1) | Read-only health report: BitLocker, Defender, pending reboot, disk, WSL, execution policy |
| [`choco_bootstrap.ps1`](choco_bootstrap.ps1) | The same five verbs over a Chocolatey `packages.config` |
| [`configuration.winget`](configuration.winget) | The curated list itself: what a workstation should have, in six commentable groups |
| [`winget-packages.example.json`](winget-packages.example.json) | A worked example of the export format, for reading before you have one |
| [`choco-packages.example.config`](choco-packages.example.config) | The same, in Chocolatey's own `packages.config` format |
| `winget-packages.json` | Written by `export`; commit it |

The scripts split the same way their Unix counterparts do: one builds the
machine, one captures and restores it, one keeps it current, one only looks.
Nothing in `workstation_doctor.ps1` changes anything, which is why it is the
safe first thing to run on a machine you have just been handed.

The distinction between the first two is the one worth reading twice.
`configuration.winget` is the *intent*: a short curated list, reviewed like
code, that says what a workstation should have. `winget-packages.json` is the
*fact*: everything one particular box happens to have, exported from it. Use
`winget_configure.ps1` to build a machine and `winget_bootstrap.ps1` to record
one. Neither replaces the other.

## winget_bootstrap.ps1

The Windows counterpart of
[`macos-initial-setup/brewfile.sh`](../../macos-initial-setup/brewfile.sh) — same
same command and exit-code conventions, same idea. A curated install list is the *intent*;
this file is the *fact*.

### Usage

```powershell
# What has changed on this machine since the file was written?
.\winget_bootstrap.ps1 diff

# Stable package ids for inventory scripts and pipes (writes no profile file)
.\winget_bootstrap.ps1 list

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

The import preview lists every package the file asks winget to ensure. It does
not launch winget: even `winget export` populates source caches, which would
make a supposedly no-write dry run mutate the machine. The real import retains
winget's normal missing-package detection.

### Exit codes

Matching `brewfile.sh`, so either can be driven from the same automation:

| Code | Meaning |
| --- | --- |
| `0` | Success. For `check`: everything is installed. |
| `1` | The command failed. For `check`: something is missing. |
| `2` | Preflight failed — not Windows, or `winget` is not on `PATH`. |
| `3` | Bad arguments, or no verb given. |

### Things worth knowing

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

### `winget-packages.example.json`

An example of what `export` writes, committed so the format is readable without
a Windows machine to hand — the same role `Brewfile.example` plays next to
`brewfile.sh`. It lists five ids most machines want anyway (`Git.Git`,
`Microsoft.VisualStudioCode`, `Microsoft.WindowsTerminal`,
`Microsoft.PowerShell`, `7zip.7zip`), and it is a valid import file:

```powershell
.\winget_bootstrap.ps1 import -DryRun -File .\winget-packages.example.json
```

It is an example, not this repository's package list. On a real machine, run
`export` and commit what comes out; the `CreationDate` and `WinGetVersion` in
here are placeholders and mean nothing.

## stay_fresh.ps1

Recurring maintenance, and the Windows sibling of
[`linux/stay_fresh.sh`](../../linux/stay_fresh.sh) and
[`macos-initial-setup/stay_fresh.sh`](../../macos-initial-setup/stay_fresh.sh):
same shape, same exit codes, same rule that a missing tool is a note rather than
a failure.

```powershell
# See the whole run first - it changes nothing:
.\stay_fresh.ps1 -DryRun

# The usual run
.\stay_fresh.ps1

# Packages only, on a machine with no WSL worth touching
.\stay_fresh.ps1 -SkipWsl

# Run exactly one section (the other maintenance steps are not invoked)
.\stay_fresh.ps1 -DryRun -Only Winget
.\stay_fresh.ps1 -Only Report
```

| Step | What it runs | Skip with |
| --- | --- | --- |
| winget | `source update`, then `upgrade --all --include-unknown` | `-SkipWinget` |
| wsl | `wsl --update` | `-SkipWsl` |
| store | Nothing — prints how to update Store apps by hand | — |
| report | Pending-reboot registry flags, free space on `C:` | — |

`-Only Winget`, `-Only Wsl`, or `-Only Report` selects one section without a
long inverse list of skip flags. `All` is the unchanged default; the existing
`-SkipWinget` and `-SkipWsl` still take precedence when their section is selected.

Worth knowing:

- **`--include-unknown` is passed deliberately.** Without it, winget silently
  leaves behind every package whose installed version it cannot read, which is
  the usual reason a machine reports itself up to date and is not.
- **Microsoft Store apps are not touched.** They update on their own schedule,
  and winget's `msstore` source wants each package's agreements accepted
  interactively — an unattended run cannot honestly claim to have updated them.
  The script prints the `UpdateScanMethod` incantation instead and leaves the
  choice to a person.
- **`wsl --update` updates WSL, not what is inside it.** For the distro's own
  packages, run [`linux/stay_fresh.sh`](../../linux/stay_fresh.sh) in the distro.
- **It never reboots and never deletes.** Disk space is
  [`../cleanup/clean_disk_c.ps1`](../cleanup/clean_disk_c.ps1)'s job, which has
  its own dry run and its own opt-in flags.
- **A step that exits non-zero counts.** The run keeps going and the script
  exits `1` at the end, the same way the Linux version does. Note that winget
  exits non-zero when even one package could not be upgraded.

Exit codes: `0` success, `1` one or more steps failed, `2` not Windows.

## workstation_doctor.ps1

A read-only report, mirroring
[`macos-initial-setup/workstation_doctor.sh`](../../macos-initial-setup/workstation_doctor.sh).
It looks at BitLocker, Defender, the pending-reboot flags, free space on `C:`,
whether WSL is installed and what distros it holds, and the effective execution
policy. It changes nothing, so there is nothing to preview:

```powershell
.\workstation_doctor.ps1
.\workstation_doctor.ps1 -MinFreePercent 20
```

`-Action report` is the only action, and the default. That is not decoration:
the contract checks in [`../tests/`](../tests/) require every script to offer
either `-DryRun` or a validated `-Action` with a read-only default, and a
diagnostic tool has no use for the first. `wsl_manage.ps1` satisfies the same
rule with its `list` default.

Disk warnings default to less than 10% free on `C:`. `-MinFreePercent` raises
or lowers that threshold without changing the report-only exit contract; this
is useful on large disks where 10% may still be too little operational headroom.

Every probe is best-effort. `Get-BitLockerVolume` does not exist on Home
editions, `Get-MpComputerStatus` is absent where Defender has been replaced, and
both answer more fully from an elevated prompt — anything that cannot answer
says so and the report carries on. Warnings are printed and counted, but the
exit code stays `0`; only the wrong platform (`2`) changes it.

## Testing

`winget.exe`, BitLocker and WSL do not exist on Linux, so the CI suite cannot
exercise the behaviour of these scripts — only that they parse, that
PSScriptAnalyzer is happy with them, that their comment-based help is complete,
that each one offers `-DryRun` or a validated `-Action`, and that every flag
documented above actually exists in a `param()` block. See
[`../tests/`](../tests/).

`configuration.winget` is checked by two different things, because they catch
different failures. yamllint covers its syntax (it is discovered as YAML via
`yaml-files` in `.yamllint.yml`). The static suite additionally checks its
*shape* - that it declares resources, that ids are unique, and that no
directive key exists which nobody wrote. That second check is the one that
matters: an unquoted description containing a comma ends its value inside an
inline map and turns the rest into a stray key, producing a file that is
perfectly valid YAML and the wrong document. yamllint passes it without a word.

Behaviour has to be checked on a real Windows machine. `workstation_doctor.ps1`,
`winget_bootstrap.ps1 diff` / `check`, and `stay_fresh.ps1 -DryRun` are all
read-only, so they are safe places to start.

## winget_configure.ps1

`winget_bootstrap.ps1` captures a machine. This one applies one, from
[`configuration.winget`](configuration.winget).

```powershell
# Does the file parse and do its resources resolve? (read-only)
.\winget_configure.ps1 validate

# What is in it? (read-only)
.\winget_configure.ps1 show

# Does this machine already match it? (read-only, exits 1 if it has drifted)
.\winget_configure.ps1 test

# Preview, then build
.\winget_configure.ps1 apply -DryRun
.\winget_configure.ps1 apply
```

`-File PATH` points any verb at a different configuration, the same way
`winget_bootstrap.ps1` takes one.

`test` is the verb worth putting on a schedule. It answers "has this machine
drifted from the list we agreed on" with an exit code rather than with prose -
the same shape as `winget_bootstrap.ps1 check` and `brewfile.sh check`, so all
three drive the same automation.

The `apply -DryRun` preview reads the configuration and lists what it would
ensure. It does not call winget, for the reason the import preview does not:
even winget's read-only paths populate source caches under `LOCALAPPDATA`,
which would make a supposedly no-write dry run mutate the machine.

### The configuration file

Six groups - core, work, communication, media, utilities, plus one OS-version
assertion - so a machine can be provisioned partially by commenting a block
out rather than by editing a flat list.

The assertion floor is **Windows 11 21H2** (build `10.0.22000`). Note that
`10.0.22000` is Windows 11's first build, not Windows 10 21H2, which is
`10.0.19044` - the two are easy to confuse and the file says which it means.
The floor is deliberate: Windows 10 left support in October 2025, so a machine
below it is not one to be installing a fresh workstation onto. Lower it to
`10.0.19044` if you must target Windows 10, and change the description with
it.

What is deliberately *not* in it is as much of the point as what is:

- **Linux tooling** (`kubectl`, `helm`, `k9s`, `jq`, `yq`, Terraform, Go,
  `awscli`, `azure-cli`) belongs inside WSL, where [`linux/`](../../linux/)
  already installs and tests it. A second native copy on the Windows side only
  drifts from the one you actually use.
- **VS Code extensions** are not applications. VS Code's own settings sync is
  the right mechanism; a package manager is not.
- **Chocolatey's own tooling** is meaningless without Chocolatey.

The schema is `0.2`, not v3, and that is a decision rather than an oversight.
The v3 schema needs WinGet 1.11 or newer with the `dscv3` processor - a much
narrower floor than this repository targets - and a machine below it fails with
a DSC error rather than a clear one. Moving to v3 is a one-file change once
1.11+ is a safe assumption.

### Requirements

WinGet 1.6 or newer: `winget configure` does not exist before it. The preflight
checks `winget --version` and exits 2 with the reason, rather than letting
winget fail with an unrecognised-argument error that reads like a bug in this
script. A version string it cannot parse is treated as unknown and allowed
through - refusing to run because a future winget changed its banner format
would be the worse failure.

Both the presence and version checks run at the point winget is invoked, not at
startup, so `apply -DryRun` works on a machine that does not have App Installer
yet. Previewing what a configuration would do is the first thing worth running
on a fresh box, and it reads the file rather than asking winget anything.

### Exit codes

Matching `winget_bootstrap.ps1`:

| Code | Meaning |
| --- | --- |
| 0 | Success; for `test`, the machine matches the file |
| 1 | Command failed; for `test`, the machine has drifted |
| 2 | Preflight failed (not Windows, no winget, winget too old) |
| 3 | Bad arguments |

`test` collapses winget's several non-zero HRESULTs into 1 and prints the raw
code alongside it. "Not in desired state" and "could not tell" mean the same
thing to a caller - do not trust this machine to match the file - and the
distinction is preserved in the output rather than in the exit status.

## choco_bootstrap.ps1

The Chocolatey counterpart of `winget_bootstrap.ps1`. Same five verbs, same
exit codes, so it does not matter which package manager a given machine uses.

winget is the primary one here: it ships with Windows, needs no bootstrap, and
`winget configure` gives a declarative machine definition Chocolatey has no
equivalent for. Chocolatey stays because it genuinely covers packages winget
does not, and because machines already managed with it should not have to be
rebuilt to be usable with this repository.

```powershell
.\choco_bootstrap.ps1 list            # installed ids, read-only
.\choco_bootstrap.ps1 check           # is everything in the file installed?
.\choco_bootstrap.ps1 diff            # what export would change
.\choco_bootstrap.ps1 install -DryRun # what the file asks for
.\choco_bootstrap.ps1 install
.\choco_bootstrap.ps1 export -Force
```

The `install -DryRun` preview reads the file and stops there; it does not ask
Chocolatey what is already installed. Even `choco list` creates
`%TEMP%\chocolatey` and touches `%APPDATA%`, so a preview that diffed against
the machine would make the script's own no-write claim false - and did, until
the native Windows runner caught it. `check` answers the "what is missing"
question and is allowed to talk to Chocolatey.

The file it reads and writes is `packages.config`, Chocolatey's own format, so
it is also usable without this script:

```powershell
choco install choco-packages.config -y
```

Copy [`choco-packages.example.config`](choco-packages.example.config) to
`choco-packages.config` and edit. The example is a ported version of an older
work-environment list; the comment at the top of it records the four entries
that had to change, and why -- classic Teams was retired, Sublime Text moved to
4, three JVMs collapse to one current LTS, and a decade-old Pester pin went.

`install` does not bootstrap Chocolatey itself. That means running a remote
script from an elevated shell, which is a decision worth making deliberately
rather than as a side effect of asking what is installed, so the script reports
the official command and stops when `choco` is missing.

Useful alongside it:

```powershell
choco upgrade all -y                    # upgrade everything
choco uninstall <package-name>          # remove one
```

Note `choco list --local-only` from older guides: v2 removed that flag and made
local listing the default, so it now errors. `choco list` is the current
spelling, and `choco list -r` is the machine-readable one this script parses.
