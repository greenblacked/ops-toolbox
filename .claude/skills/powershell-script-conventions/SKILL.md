---
name: powershell-script-conventions
description: How the Windows PowerShell scripts here are written and verified - the file header order, the hand-rolled -DryRun switch instead of ShouldProcess, the WOULD/CLEAN/SKIP output grammar, pure-ASCII no-BOM encoding, PSScriptAnalyzer policy, and the Get-DryRunArgument table in windows/tests/contract.ps1 that decides whether a script's dry run is exercised at all. Use this whenever you touch any .ps1 or .psd1 file in windows/ or templates/, and whenever a Windows change needs verifying.
---

# PowerShell scripts in this repository

Start from `templates/new_script.ps1` - it is tracked and the contract suite
runs against it, so it cannot silently drift from these rules.

## File shape

Comment-based help (`.SYNOPSIS`, `.DESCRIPTION`, `.EXAMPLE`), then
`[CmdletBinding()]`, then `param()`, then `$ErrorActionPreference`. The
contract suite checks the help is complete and that every flag the READMEs
document actually exists.

## `-DryRun`, not `-WhatIf`

Use a hand-rolled `[switch]$DryRun`. This is a deliberate divergence from
PowerShell convention, recorded in `CONTRIBUTING.md` and in the reasoning block
of `PSScriptAnalyzerSettings.psd1`, for two reasons: the Windows scripts should
read the same as the Bash ones, and the dry-run modes here accumulate and
report a total - bytes that *would* be freed - which `ShouldProcess` cannot
express.

## Output grammar

`Write-Host -ForegroundColor`, in a fixed column layout
(`windows/cleanup/clean_disk_c.ps1`):

```powershell
Write-Host ('WOULD {0,-38} {1,10}  ({2} files)' -f $Label, (Format-Size $size), $files.Count)
Write-Host ('CLEAN {0,-38} {1,10}' -f $Label, (Format-Size $size)) -ForegroundColor Green
Write-Host ('SKIP  {0,-38} (not found)' -f $Label) -ForegroundColor DarkGray
```

The verbs are `WOULD` / `CLEAN` / `SKIP`: the label is padded to 38 and a size
to 10, and a `SKIP` carries the reason it was skipped in place of the size.

## Encoding

Keep these files **pure ASCII with no BOM**. A stray em dash or smart quote
trips `PSUseBOMForUnicodeEncodedFile`, and adding a BOM to satisfy it fights
the LF pinning in `.gitattributes`. When you are tempted to paste an em dash
into a `.DESCRIPTION`, use a hyphen.

## PSScriptAnalyzer policy

The gate is `Severity = @('Error', 'Warning')`, not errors only: almost every
built-in rule is Warning severity, so an Error-only gate would pass a script
with real defects and report nothing.

**`PSAvoidUsingWriteHost` is the only rule excluded repository-wide**, because
these are interactive operator tools whose whole output is a colour-coded human
report - `Write-Output` would put that on the pipeline and `Write-Information`
is off by default.

`PSUseShouldProcessForStateChangingFunctions` is **not** excluded, which
surprises people given the hand-rolled `-DryRun`. It was expected to fire and
does not: the rule needs `[CmdletBinding()]` on the function itself, and the
state-changing helpers declare a bare `param()`. It stays enabled deliberately,
to catch a future function that does take `CmdletBinding` without a dry-run
story - so if you add one and the analyzer complains, give it a dry-run path
rather than widening the exclusions. Everything else reported at `Warning` or
above is a real finding.

`PSUseBOMForUnicodeEncodedFile` is likewise kept on purpose, as the guard
behind the ASCII rule above.

For a genuine one-off, use `[Diagnostics.CodeAnalysis.SuppressMessageAttribute()]`
at the site with a non-empty `Justification`. Repository-wide policy belongs in
the settings file, where it gets explained once.

## A preview must not invoke the packaging tool

This is the Windows-specific trap, and it has already produced a real defect.
`choco list` creates `%TEMP%\chocolatey` and touches `%APPDATA%` - which is how
`choco_bootstrap.ps1 install -DryRun` wrote two directories while claiming it
had written none. A `-DryRun` that asks the machine what it already has cannot
keep the repository's second promise.

So: read the file and report what it *asks for*. Leave "what is actually
missing" to `check`, which is allowed to talk to the tool. `winget --version`
was measured writing nothing on `windows-2025`, so a version preflight is not
known to break this - but call it at the point of use anyway, so the preview
path invokes nothing at all.

## Verifying a change - and why a green local run proves little

`test-env/static/check_conventions.sh` is bash and python only; **it does not
cover `.ps1` files at all**. `windows/tests/contract.ps1` is the sole place
their help, preview and no-write contracts are checked, and it skips itself
silently when `pwsh` is missing. Install `pwsh` before believing a green local
run.

```bash
./run-tests.sh windows
pwsh -NoProfile -File windows/tests/contract.ps1
pwsh -c 'Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1'
```

Two more things decide whether that run means anything:

- **A new `.ps1` under `windows/` is discovered automatically, but if it needs
  arguments to reach its write path, add it to `Get-DryRunArgument` in
  `windows/tests/contract.ps1`.** Otherwise the suite runs a bare `-DryRun`,
  the script exits at its usage branch, and "wrote nothing" is true of a run
  that never reached the code that writes.
- **On Linux every one of these scripts exits at its `$IsWindows` guard before
  the preview path runs.** A green `./run-tests.sh windows` on Linux proves
  nothing about the dry-run promise. The `windows-2025` runner is the only gate
  that executes it for real - which is why a Windows change is worth waiting
  for CI on rather than pushing behind.

Two Windows failures reached `master` exactly this way. When you report what
you ran, say which platform ran it.
