---
name: pre-push-gates
description: The checks that must pass before pushing here and that run-tests.sh does not cover - markdownlint-cli2, actionlint, shellcheck, PSScriptAnalyzer, yamllint - plus how CI is wired (path-filtered jobs, pull-request-only triggers on typed branches, pinned action SHAs) and why a green local run can still turn the default branch red. Use this before every push or pull request in this repository, when CI is red and local was green, or when editing anything under .github/.
---

# Before you push

`./run-tests.sh` is the single test entry point, but **it does not cover the
Lint job**. That gap has turned the default branch red more than once. Run the
gates CI runs:

```bash
npx --yes markdownlint-cli2 "**/*.md"   # MD024 siblings_only bites changelog edits
actionlint                              # needs shellcheck on PATH for run: blocks
shellcheck -x --severity=error $(git ls-files '*.sh')
pwsh -c 'Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1'
yamllint --config-file .yamllint.yml .
```

All of these are installable in a sandbox - via `npx`, a release tarball, or a
package manager. **Treating one as unavailable without checking is how both of
those red builds happened.** If a tool genuinely cannot be installed, say so
explicitly rather than reporting a clean run.

## How CI is arranged, and what that means for you

`.github/workflows/ci.yml`:

- A `Detect changes` job decides which languages and suites a change actually
  touches, and **fails open** - anything it is unsure about runs everything.
  Jobs are never skipped at the job level, precisely so a required check always
  reports; a skipped step reports a skip instead.
- `pull_request` covers development branches and tests the **merge result**,
  which a branch push cannot. `push` covers only `master`. Each event owns one
  path so a change is built once rather than twice.
- The pull-request filter lists **target** branches: `master`, `feat/**`,
  `feature/**`, `ci/**`, `chore/**`, `fix/**`. A target branch matching no
  pattern does not fail - it merges green because nothing ever ran, which is
  the worst way for a filter to be wrong. If you introduce a new branch prefix,
  add it there.
- The tradeoff, stated plainly in the file: a typed branch with no pull request
  open gets no CI. Open the pull request as a draft, or use
  `workflow_dispatch`, if you want a verdict before review.
- Actions are pinned to a commit SHA with the version in a trailing comment.
  Keep that form when adding or bumping one; Dependabot maintains them as a
  group.

## The two platform gates local runs cannot stand in for

- **Windows.** On Linux every `.ps1` here exits at its `$IsWindows` guard
  before the preview path runs. The `windows-2025` runner is the only gate that
  executes a dry run for real, which is why a Windows change is worth waiting
  for CI on rather than pushing behind.
- **macOS.** The `Test / macos native` job runs the contracts under Apple's
  Bash 3.2. That is the gate that catches a Bash 4 construct the static
  suite's regex missed.

## Separate workflows

`chr.yml` (RouterOS CHR under QEMU) runs nightly rather than on the
pull-request path, so a red badge there does not necessarily mean a red pull
request. `routeros-version.yml` runs twice a week and opens its own tested bump
pull request. `k8s-image-smoke.yml` builds the toolbox image on demand.

## Reporting

Say which gates ran and which did not, and on what platform. "Lint passed"
without naming the four tools is the claim that preceded both red builds.
