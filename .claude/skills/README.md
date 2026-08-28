# Repository skills

Task-scoped conventions for this repository, written for an automated coding
agent and readable by a human. Each skill is a single `SKILL.md` whose front
matter says when it applies; a tool that supports this format loads only the
ones relevant to the file being touched, which is why the material is split by
task rather than kept as one long document.

Nothing here is new policy. Everything is extracted from what the scripts and
the test suites already do, with the file and line that establishes it.
[`CONTRIBUTING.md`](../../CONTRIBUTING.md) remains the prose reference and
[`AGENTS.md`](../../AGENTS.md) the short brief; when a skill and the scripts
disagree, the scripts are right and the skill is the bug.

| Skill | Read it when |
| --- | --- |
| [`ops-toolbox-conventions`](ops-toolbox-conventions/SKILL.md) | Anything at all — the three promises, exit codes, the package map, and which skill to open next |
| [`bash-script-conventions`](bash-script-conventions/SKILL.md) | Writing or editing a `.sh` file |
| [`powershell-script-conventions`](powershell-script-conventions/SKILL.md) | Writing or editing a `.ps1` file |
| [`routeros-script-conventions`](routeros-script-conventions/SKILL.md) | Writing or editing a RouterOS script under `mikrotik/` |
| [`python-helper-conventions`](python-helper-conventions/SKILL.md) | Writing or editing a `.py` helper |
| [`adding-a-script`](adding-a-script/SKILL.md) | Adding a new script of any language, end to end |
| [`running-tests`](running-tests/SKILL.md) | Running, adding or debugging a test |
| [`pre-push-gates`](pre-push-gates/SKILL.md) | Before pushing, or when CI is red and local was green |
| [`docs-and-changelog`](docs-and-changelog/SKILL.md) | Editing a README, the changelog, or any Markdown |
| [`commits-and-prs`](commits-and-prs/SKILL.md) | Committing, branching, or opening a pull request |

The directory name is fixed by the tooling that reads these files; the content
is plain Markdown and stays useful without it.

## Keeping them honest

A skill that describes a convention nobody enforces will drift, so each one
cites the check that would fail — `test-env/static/check_conventions.sh`,
`windows/tests/contract.ps1`, `mikrotik/tests/test_lua_conventions.sh`. When a
check changes, update the skill that quotes it in the same commit, the same way
a changed flag updates both READMEs.
