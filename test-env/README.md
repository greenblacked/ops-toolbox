# test-env

Sandboxes for automated checks that do not live inside the main script trees
(`git/`, `macos-initial-setup/`, `mikrotik/`). Each subfolder (`chef/`, `python/`,
`go/`) is self-contained: Docker on the host, optional `just`, and its own README.

Every sandbox lints two layers:

1. **Target code** — Cookstyle (Chef), Ruff (Python), golangci-lint (Go).
2. **Test-env scaffolding** — `shellcheck` on `run.sh`, `hadolint` on the
   `Dockerfile`, `yamllint` on compose / config YAML. Exposed everywhere as
   `just lint-env`, and wired into `just ci`.

The runner images bake all linters in; `./run.sh shellcheck ...` /
`./run.sh hadolint ...` work in any of the three envs.

## Chef (`chef/`)

**[`chef/`](chef/)** — Chef Infra cookbook toolchain in one place:

- **Docker runner** — [`chef/run.sh`](chef/run.sh) starts a Compose service with
  Ruby, gems, the Docker CLI, **yamllint**, **shellcheck**, and **hadolint**;
  mounts this repo at `/chef` and the host **`/var/run/docker.sock`** so
  [kitchen-dokken](https://github.com/test-kitchen/kitchen-dokken) can start
  converge containers on your machine.
- **Linters** — Cookstyle on cookbooks; shellcheck/hadolint/yamllint on the
  scaffolding via `just lint-env`. ChefSpec for unit tests, Kitchen + InSpec
  for integration.
- **Tasks** — [`chef/justfile`](chef/justfile): `just lint`, `just lint-env`,
  `just yamllint`, `just spec`, `just verify`, `just ci`, …
- **Editor** — [`.devcontainer/`](chef/.devcontainer/) reuses the same image
  for VS Code / Cursor.

Full commands, layout table, and cookbook authoring notes:
**[`chef/README.md`](chef/README.md)**.

## Python (`python/`)

**[`python/`](python/)** — Python 3.12 in Docker with **Ruff** (lint + format),
**pytest**, and **mypy**:

- **Docker runner** — [`python/run.sh`](python/run.sh) starts a long-running
  Compose `dev` service, mounts `test-env/python` at `/python`, and `exec`s
  commands so repeated runs stay fast.
- **Linters** — Ruff on source; **shellcheck**, **hadolint**, and **yamllint**
  on the scaffolding via `just lint-env`. mypy for typing.
- **Tasks** — [`python/justfile`](python/justfile): `just lint`,
  `just lint-env`, `just format-check`, `just typecheck`, `just test`,
  `just ci`, …
- **Editor** — [`.devcontainer/`](python/.devcontainer/) reuses the same image
  for VS Code / Cursor.

Details and layout table: **[`python/README.md`](python/README.md)**.

## Go (`go/`)

**[`go/`](go/)** — Go 1.23 in Docker with **golangci-lint**, **goimports**, and
**govulncheck**:

- **Docker runner** — [`go/run.sh`](go/run.sh) starts a long-running Compose
  `dev` service; module and build caches live in named volumes so rebuilds are
  fast.
- **Linters** — golangci-lint + `go vet` on source; govulncheck for CVEs;
  **shellcheck**, **hadolint**, and **yamllint** on the scaffolding via
  `just lint-env`.
- **Tasks** — [`go/justfile`](go/justfile): `just test`, `just lint`,
  `just lint-env`, `just vet`, `just cov`, `just vuln`, `just ci`, …
- **Editor** — [`.devcontainer/`](go/.devcontainer/) reuses the same image
  for VS Code / Cursor.

Details and layout table: **[`go/README.md`](go/README.md)**.
