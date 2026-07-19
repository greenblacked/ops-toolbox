# Contributing

Create changes from the default `master` branch and keep each branch focused on
one topic. Use a short, descriptive branch name; automated coding agents use
the `agent/<description>` pattern.

## Local validation

The pull request workflow runs linting and the two lightweight Docker test
suites. To reproduce the test jobs, install Docker Engine with Compose v2 and
run these commands from the repository root:

```bash
./git/tests/run.sh
./macos-initial-setup/tests/run.sh
```

The lint job checks every tracked `*.sh` file with `bash -n` and ShellCheck,
all YAML with yamllint, and all Markdown with markdownlint-cli2. On Debian or
Ubuntu, install the command-line linters and run the equivalent checks with:

```bash
sudo apt-get install shellcheck yamllint

mapfile -d '' scripts < <(git ls-files -z '*.sh')
bash -n "${scripts[@]}"
shellcheck --severity=error --shell=bash "${scripts[@]}"
yamllint --config-file .yamllint.yml .
npx markdownlint-cli2 --config .markdownlint-cli2.yaml '**/*.md'
```

## RouterOS integration tests

The MikroTik suite boots RouterOS CHR under QEMU and can take much longer than
the portable suites. Run it locally with:

```bash
./mikrotik/tests/run.sh
```

In GitHub Actions, open the **CI** workflow, choose **Run workflow**, and enable
**Run the RouterOS CHR integration suite**. It is intentionally opt-in for
routine pushes and pull requests.

## Pull requests

Before requesting review, confirm the lint and test jobs pass and describe:

- what changed and why;
- any user-visible or developer-visible impact;
- which validation commands were run;
- any checks that could not be run locally.
