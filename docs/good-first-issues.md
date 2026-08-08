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
./run-tests.sh python static k8s      # no Docker needed
npx markdownlint-cli2 --config .markdownlint-cli2.yaml '**/*.md'
```

## Contents

- [1. Document `macos_defaults.sh` in the macOS README](#1-document-macos_defaultssh-in-the-macos-readme)
- [2. Add the three missing script sections to `git/README.md`](#2-add-the-three-missing-script-sections-to-gitreadmemd)
- [3. Give `git/README.md` a table of contents](#3-give-gitreadmemd-a-table-of-contents)
- [4. Add an issue-template `config.yml`](#4-add-an-issue-template-configyml)
- [5. Behavioural tests for `git_prune_gone.sh` and `git_size_report.sh`](#5-behavioural-tests-for-git_prune_gonesh-and-git_size_reportsh)
- [Resolved](#resolved)

## 1. Document `macos_defaults.sh` in the macOS README

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

## 2. Add the three missing script sections to `git/README.md`

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

## 3. Give `git/README.md` a table of contents

**File:** `git/README.md`

It has eighteen headings and no table of contents, where
`macos-initial-setup/README.md` and the top-level `README.md` both have one.
Add a `## Contents` list of links directly after the intro paragraph, matching
the style of the other two.

Worth doing after issue 2 so the new sections are included, or before it, with
issue 2 adding its three entries.

**Verify:**

```bash
grep -n '^#\{2,3\} ' git/README.md
npx markdownlint-cli2 --config .markdownlint-cli2.yaml 'git/README.md'
```

Every `##` in that output should have a matching entry, and every anchor should
be the heading lowercased with punctuation stripped and spaces turned into
hyphens.

## 4. Add an issue-template `config.yml`

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

## 5. Behavioural tests for `git_prune_gone.sh` and `git_size_report.sh`

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

## Resolved

Removed from the list above once the tree stopped matching the description.
Kept as a short record, because the point of this file is that every entry is a
real gap and a stale one undermines the rest.

- **`NO_COLOR` in the seven scripts that ignored it.** All of them test the
  variable as well as the terminal now:
  `grep -rl 'C_RESET=' --include='*.sh' . | xargs grep -L 'NO_COLOR'` prints
  nothing.
- **The stale `NO_COLOR` sentence in `CONTRIBUTING.md`.** The Output section
  says every Bash script honours it, which is what the tree does.
- **The two out-of-date test descriptions in `README.md`.** The Testing section
  lists the current fast selection, and the Continuous integration section says
  every suite except the RouterOS one.
- **`templates/new_script.ps1` outside the PowerShell contract suite.**
  `windows/tests/contract.ps1` discovers `templates/*.ps1` alongside
  `windows/`, so the template's help and its dry run are checked like
  everything else.
