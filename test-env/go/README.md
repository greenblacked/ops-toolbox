# Go test environment

Develop and run checks in **Docker** so your laptop does not need a local Go
toolchain. The image ships **Go 1.23**, **golangci-lint**, **goimports**,
**govulncheck**, plus the meta-linters **shellcheck**, **hadolint**, and
**yamllint** for the test-env scaffolding itself. Module + build caches live
in named Compose volumes so recompiles are quick.

The stack keeps a **long-running dev container** so every `run.sh` invocation
`docker compose exec`s into it — milliseconds, not seconds.

---

## Layout

| Path | Role |
| --- | --- |
| [`run.sh`](run.sh) | Entrypoint. Subcommands: `up`/`down`/`logs`/`ps`/`shell`. Flags: `--once`, `--rebuild`. |
| [`justfile`](justfile) | Shortcuts: `just up`, `just test`, `just lint`, `just ci`, … |
| [`docker/Dockerfile`](docker/Dockerfile) | `golang:1.23-bookworm` + golangci-lint + goimports + govulncheck + **shellcheck / hadolint / yamllint** |
| [`docker/docker-compose.yml`](docker/docker-compose.yml) | Long-running `dev` service, `go-mod-cache` + `go-build-cache` volumes |
| [`.golangci.yml`](.golangci.yml) | Lint config (errcheck, staticcheck, gosec, revive, …) |
| [`go.mod`](go.mod) | Module — `github.com/pretty-useful-scripts/test-env/go` |
| [`internal/sample/`](internal/sample/) | Sample package with table test |
| [`cmd/hello/`](cmd/hello/) | Sample binary that prints `sample.Greet(...)` |
| [`.devcontainer/`](.devcontainer/) | VS Code / Cursor dev container (same image) |
| [`.editorconfig`](.editorconfig) | Tabs for Go, spaces for everything else |

---

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) with **Compose v2**
- Optional: [`just`](https://github.com/casey/just)

---

## Quick start

From **`test-env/go`**:

```bash
./run.sh up                       # start container in the background
./run.sh go test ./...            # exec inside it
./run.sh golangci-lint run
./run.sh govulncheck ./...
./run.sh go run ./cmd/hello dock  # try the sample binary
./run.sh shellcheck run.sh        # lint the scaffolding itself
./run.sh hadolint docker/Dockerfile
./run.sh yamllint docker/docker-compose.yml .golangci.yml
./run.sh shell                    # interactive bash
./run.sh down
```

With **`just`**:

```bash
just up           # start container
just build        # go build ./...
just test         # go test -race
just cov          # coverage report
just lint         # golangci-lint (Go source)
just lint-env     # shellcheck + hadolint + yamllint (scaffolding)
just vet          # go vet
just format       # goimports -w
just vuln         # govulncheck
just tidy         # go mod tidy
just ci           # lint-env + vet + lint + format-check + test + vuln
just hello docker # run the sample binary
just shell
just down
```

The container survives between commands, so the second `go test` is fast —
the build cache stays warm in the `go-build-cache` volume.

## One-shot mode

```bash
./run.sh --once go test ./...
./run.sh --once --shell
```

## After dependency changes

`go.mod` / `Dockerfile` changed? Rebuild:

```bash
./run.sh --rebuild
./run.sh down && ./run.sh up
```

Module cache lives in a named volume, so a rebuild still reuses downloaded
modules.

---

## Linters

| Target | Tool | Recipe |
| --- | --- | --- |
| Go source | golangci-lint (errcheck, staticcheck, gosec, revive, …) | `just lint` |
| Go format | gofmt + goimports | `just format-check` / `just format` |
| Static analysis | `go vet` | `just vet` |
| Vulnerabilities | govulncheck | `just vuln` |
| Shell scripts (`run.sh`) | shellcheck | `just lint-env` |
| Dockerfile | hadolint | `just lint-env` |
| YAML (`docker-compose.yml`, `.golangci.yml`) | yamllint | `just lint-env` |

`just ci` chains them all together with the tests.

---

## Optional: Go on the host

If you already have Go **1.23+**:

```bash
cd test-env/go
go test ./...
go run ./cmd/hello docker
```
