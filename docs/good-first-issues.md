# Good first issues

Small, self-contained tasks, each one a real gap that exists in the tree today
rather than invented busywork. Every entry names the file to change and the
command that tells you whether the change worked.

Read [`CONTRIBUTING.md`](../CONTRIBUTING.md) first — it is short, and it is
where the conventions these tasks ask you to follow are written down with the
file and line that establishes each one.

Before you start, get a green baseline so you can tell your change apart from
something that was already broken:

```bash
./run-tests.sh python static          # no Docker needed
npx markdownlint-cli2 --config .markdownlint-cli2.yaml '**/*.md'
```

## Contents

- [1. Honour `NO_COLOR` in the scripts that still ignore it](#1-honour-no_color-in-the-scripts-that-still-ignore-it)
- [2. Fix the stale `NO_COLOR` claim in CONTRIBUTING.md](#2-fix-the-stale-no_color-claim-in-contributingmd)
- [3. Fix the two out-of-date test descriptions in README.md](#3-fix-the-two-out-of-date-test-descriptions-in-readmemd)
- [4. Document `macos_defaults.sh` in the macOS README](#4-document-macos_defaultssh-in-the-macos-readme)
- [5. Add the three missing script sections to `git/README.md`](#5-add-the-three-missing-script-sections-to-gitreadmemd)
- [6. Give `git/README.md` a table of contents](#6-give-gitreadmemd-a-table-of-contents)
- [7. Add an issue-template `config.yml`](#7-add-an-issue-template-configyml)
- [8. Behavioural tests for `git_prune_gone.sh` and `git_size_report.sh`](#8-behavioural-tests-for-git_prune_gonesh-and-git_size_reportsh)
- [9. Cover `templates/new_script.ps1` with the PowerShell contract suite](#9-cover-templatesnew_scriptps1-with-the-powershell-contract-suite)

## 1. Honour `NO_COLOR` in the scripts that still ignore it

**Files:** `git/set_git_profile.sh`, `macos-initial-setup/brewfile.sh`,
`macos-initial-setup/install_apps.sh`,
`macos-initial-setup/install_devtools.sh`,
`macos-initial-setup/stay_fresh.sh`, `macos-initial-setup/v1_stay_fresh.sh`,
`macos-initial-setup/launchd/stay_fresh_agent.sh`

The colour block in [`templates/new_script.sh`](../templates/new_script.sh) —
the form `CONTRIBUTING.md` tells you to copy — guards on both the terminal and
the environment variable:

```bash
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
```

`linux/*.sh`, `macos-initial-setup/macos_defaults.sh`, `run-tests.sh` and the
Python helpers already do this. The seven scripts above still test `[[ -t 1 ]]`
alone, so `NO_COLOR=1` does nothing for them. Add the second condition.
`v1_stay_fresh.sh` is the odd one out: its guard also consults `tput colors`, so
add the check rather than replacing the block wholesale.

**Verify:**

```bash
grep -rl 'C_RESET=' --include='*.sh' . | xargs grep -L 'NO_COLOR'
./run-tests.sh static
```

The first command lists every script that defines colours without honouring
`NO_COLOR` — today it prints exactly those seven, and it should print nothing
when the change is complete. Colour is
already suppressed when output is not a terminal, so checking the effect needs a
real terminal — run one of the scripts with `--help` in your own shell, with and
without `NO_COLOR=1`. Nothing here changes behaviour when the variable is unset,
and `--help` still exits `0`.

## 2. Fix the stale `NO_COLOR` claim in CONTRIBUTING.md

**File:** `CONTRIBUTING.md`, the Output section

It says "New scripts also honour `NO_COLOR`; today only `run-tests.sh:20` and
the Python helpers do". That is no longer true: `linux/install_devtools.sh`,
`linux/packages.sh`, `linux/stay_fresh.sh`,
`macos-initial-setup/macos_defaults.sh` and `templates/new_script.sh` all honour
it as well. Rewrite the sentence to match what the tree actually does — the file
opens by saying that a rule the scripts do not follow is a wrong rule, and this
is a small instance of exactly that.

If issue 1 lands first, this becomes "every script does", which is simpler
still. Either order works; whoever goes second updates the sentence again.

**Verify:**

```bash
grep -rln 'NO_COLOR' --include='*.sh' .
npx markdownlint-cli2 --config .markdownlint-cli2.yaml 'CONTRIBUTING.md'
```

The list the grep prints is the list the sentence should describe.

## 3. Fix the two out-of-date test descriptions in README.md

**File:** `README.md`, the Testing and Continuous integration sections

Two statements have fallen behind the code:

- The Testing section says `./run-tests.sh` runs
  "git + macos + python + static (the fast default)". `run-tests.sh:35` sets
  `SUITE_FAST="git macos linux python static windows"`.
- The Continuous integration section says `ci.yml` "runs the git, macOS, Python
  and static suites". The matrix in `.github/workflows/ci.yml` also includes
  `linux` and `windows`.

Note that the badge paragraph at the top of the same README already lists all
six correctly, so the fix is to make the two later mentions agree with it.

**Verify:**

```bash
./run-tests.sh --help          # the `fast` line is the authority
grep -n 'suite:' .github/workflows/ci.yml
npx markdownlint-cli2 --config .markdownlint-cli2.yaml 'README.md'
```

## 4. Document `macos_defaults.sh` in the macOS README

**File:** `macos-initial-setup/README.md`

`macos_defaults.sh` is in the folder and described in the top-level README, but
`macos-initial-setup/README.md` never mentions it: not in the table of contents,
not in the folder map table, and it has no section of its own while every other
script in the package does.

Add all three. The section wants the same shape as its neighbours — a sentence
on what it is for, a usage block, an options list, exit codes. The material is
in the script's own `--help` and header comment, including the part worth
repeating: it is read-only with no flags, `--apply` writes, `--revert` restores
the values captured by the last apply, and each row records the macOS version it
was checked against.

**Verify:**

```bash
./macos-initial-setup/macos_defaults.sh --help
npx markdownlint-cli2 --config .markdownlint-cli2.yaml 'macos-initial-setup/README.md'
```

Then click each new table-of-contents link on your fork and confirm it lands on
the heading it names.

## 5. Add the three missing script sections to `git/README.md`

**File:** `git/README.md`

The file gives every Git helper a section of its own with copy-pasteable
examples — except `git_prune_gone.sh`, `git_size_report.sh` and
`git_signing_doctor.py`, which appear only as one-line rows in the Scripts
overview table. Those three are among the most useful in the folder and the
hardest to guess the flags for.

Add a section for each, following the existing shape. Take the content from
`--help`; do not invent flags.

**Verify:**

```bash
./git/git_prune_gone.sh --help
./git/git_size_report.sh --help
./git/git_signing_doctor.py --help
npx markdownlint-cli2 --config .markdownlint-cli2.yaml 'git/README.md'
```

Every flag you document must appear in the matching `--help` output.

## 6. Give `git/README.md` a table of contents

**File:** `git/README.md`

It has eighteen headings and no table of contents, where
`macos-initial-setup/README.md` and the top-level `README.md` both have one.
Add a `## Contents` list of links directly after the intro paragraph, matching
the style of the other two.

Worth doing after issue 5 so the new sections are included, or before it, with
issue 5 adding its three entries.

**Verify:**

```bash
grep -n '^#\{2,3\} ' git/README.md
npx markdownlint-cli2 --config .markdownlint-cli2.yaml 'git/README.md'
```

Every `##` in that output should have a matching entry, and every anchor should
be the heading lowercased with punctuation stripped and spaces turned into
hyphens.

## 7. Add an issue-template `config.yml`

**File:** `.github/ISSUE_TEMPLATE/config.yml` (new)

`.github/ISSUE_TEMPLATE/` contains `bug_report.md` and `script_request.md` and
nothing else. Without a `config.yml`, the "New issue" page offers those two
templates plus a blank issue, and there is no pointer to
[`SECURITY.md`](../SECURITY.md) — so the natural place to report a script that
deletes more than it says it will is a public issue, which is exactly what
`SECURITY.md` asks people not to do.

Add a `config.yml` with `blank_issues_enabled` set deliberately and a
`contact_links` entry pointing at the private security advisory form. If
Discussions is enabled by then (see the Repository settings checklist in
[`CONTRIBUTING.md`](../CONTRIBUTING.md)), add a second link for questions.

**Verify:**

```bash
yamllint -c .yamllint.yml .github/ISSUE_TEMPLATE/config.yml
```

The rendered result cannot be checked from a clone — open the "New issue" page
on your own fork and confirm the links appear.

## 8. Behavioural tests for `git_prune_gone.sh` and `git_size_report.sh`

**File:** `git/tests/test_git_scripts.sh`

The suite defines a variable per script it covers and there are eleven of them.
`git_prune_gone.sh` and `git_size_report.sh` are not among them, so their only
coverage is the repository-wide `--help` and unknown-flag contract from the
static suite. `git_prune_gone.sh` deletes branches, which is the kind of thing
that should not be tested by hand only.

Useful cases, all buildable with the temporary repositories and local bare
remotes the suite already sets up:

- `git_prune_gone.sh --dry-run` deletes nothing and names the branch it would
  have deleted.
- A branch whose upstream still exists survives.
- The output includes the restore command for each branch it removes — the
  script promises this, and nothing checks it.
- `git_size_report.sh --fast` skips the history walk and still exits `0`.

Follow the conventions in the Tests section of `CONTRIBUTING.md`: hand-rolled
harness, no framework, and the `set +e` sandwich when asserting an exit code.

**Verify:**

```bash
./run-tests.sh git     # needs Docker
```

Then break the script on purpose — make the dry run delete a branch — and
confirm your test goes red. A test that cannot fail is worse than no test.

## 9. Cover `templates/new_script.ps1` with the PowerShell contract suite

**File:** `windows/tests/contract.ps1`

Discovery at line 41 is scoped to `windows/**/*.ps1`, so
`templates/new_script.ps1` is checked by repository-wide PSScriptAnalyzer in CI
but not by the contract suite — its comment-based help completeness and its
preview-before-changing behaviour go unverified.
[`templates/README.md`](../templates/README.md) explains why that matters: the
templates exist so the conventions cannot drift away from them, and CI is
supposed to fail here first.

Extend the discovery to include `templates/*.ps1` alongside `windows/`, keeping
the existing exclusion of anything under a `tests/` directory. The template is a
working no-op, so it should pass unchanged — if it does not, that is the finding
and the template is what needs the fix.

**Verify:**

```bash
./run-tests.sh windows          # needs pwsh; skips cleanly without it
```

The run should report one more script than before and stay green.
