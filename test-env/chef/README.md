# Chef cookbook test environment

Cookbooks are exercised with [Test Kitchen](https://kitchen.ci/) using the
**[kitchen-dokken](https://github.com/test-kitchen/kitchen-dokken)** driver:
Chef is pre-installed in upstream `dokken/*` images, so converges are faster
than a plain `kitchen-docker` flow.

**Cookstyle** (RuboCop rules for Chef), **ChefSpec**, and **InSpec** (via
Kitchen) lint and test the cookbooks themselves. Meta-linters **shellcheck**,
**hadolint**, and **yamllint** keep the test-env scaffolding (run.sh, the
Dockerfile, compose, kitchen.yml) honest. Everything runs in the same
**Docker runner**; the host only needs **Docker Engine + Compose v2**.

---

## Layout

| Path | Role |
| --- | --- |
| [`run.sh`](run.sh) | Primary entrypoint. Subcommands: `up`/`down`/`logs`/`ps`/`shell`. Flags: `--once`, `--rebuild`. |
| [`justfile`](justfile) | Shortcuts: `just lint`, `just spec`, `just verify`, `just ci`, … |
| [`docker/Dockerfile`](docker/Dockerfile) | `ruby:3.3-bookworm-slim`, build deps, Docker static CLI, `bundle install`, **shellcheck / hadolint / yamllint** |
| [`docker/docker-compose.yml`](docker/docker-compose.yml) | Long-running `kitchen` service, mounts `..` → `/chef` and `/var/run/docker.sock` |
| [`docker/entrypoint.sh`](docker/entrypoint.sh) | `bundle check \|\| bundle install`, then `bundle exec` (passes `yamllint` / `shellcheck` / `hadolint` / `docker` / `bash` / `sh` straight through) |
| [`kitchen.yml`](kitchen.yml) | dokken driver; platforms **Ubuntu 22.04/24.04**, **Debian 12**, **Rocky Linux 9**; suite `example` |
| [`Gemfile`](Gemfile) | test-kitchen, kitchen-dokken, kitchen-inspec; Cookstyle + ChefSpec + Berkshelf in groups |
| [`.rubocop.yml`](.rubocop.yml), [`.rspec`](.rspec) | Cookstyle + ChefSpec |
| [`.yamllint`](.yamllint), [`.editorconfig`](.editorconfig) | YAML + editor defaults |
| [`.devcontainer/`](.devcontainer/) | Dev container definition (same stack as the runner) |
| [`cookbooks/`](cookbooks/) | Your cookbooks. **`example`** includes Policyfile (sample), ChefSpec, and InSpec |

---

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) with **Compose v2**
- Optional: [`just`](https://github.com/casey/just) for [`justfile`](justfile) tasks

---

## Quick start (long-running container — recommended)

From **`test-env/chef`**:

```bash
./run.sh up                          # start runner container in the background
./run.sh kitchen verify              # exec — fast (no container re-create)
./run.sh cookstyle --display-cop-names cookbooks
./run.sh yamllint -c .yamllint .
./run.sh rspec cookbooks
./run.sh shellcheck run.sh docker/entrypoint.sh   # lint the scaffolding
./run.sh hadolint docker/Dockerfile
./run.sh shell                       # interactive bash inside the runner
./run.sh down                        # stop
```

With **`just`**:

```bash
just up          # start runner
just lint        # Cookstyle (cookbooks)
just lint-env    # shellcheck + hadolint + yamllint (scaffolding)
just yamllint    # yamllint over the whole tree
just spec        # ChefSpec (no Kitchen containers)
just verify      # kitchen verify (all platforms in kitchen.yml)
just ci          # lint-env + lint + yamllint + spec + kitchen verify ubuntu-2204
just shell       # interactive shell
just down        # stop
```

The runner stays alive between commands, so the second `kitchen` invocation
skips container creation and gem load. Kitchen-dokken still spins up *test*
containers as host siblings via the mounted Docker socket.

## One-shot mode

`./run.sh --once kitchen list` runs a throwaway container (old `run --rm`
behavior). Useful in CI scripts where you don't want lingering state.

Fast inner loop before Kitchen: **`just lint && just yamllint && just spec`**.

---

## Linters

| Target | Tool | Recipe |
| --- | --- | --- |
| Cookbooks (Ruby) | Cookstyle | `just lint` |
| Cookbook YAML | yamllint | `just yamllint` |
| Unit tests | ChefSpec / RSpec | `just spec` |
| Integration tests | Test Kitchen + InSpec | `just verify` |
| Shell scripts (`run.sh`, `entrypoint.sh`) | shellcheck | `just lint-env` |
| Dockerfile | hadolint | `just lint-env` |
| YAML (`docker-compose.yml`, `kitchen.yml`) | yamllint | `just lint-env` |

`just ci` chains the local-fast layers (lint-env → lint → yamllint → spec)
plus one Kitchen platform.

---

## How it works

1. **`run.sh`** builds (when needed) and runs the **kitchen** Compose service.
2. The container runs **`bundle exec`** for Ruby tools; **yamllint** is invoked
   as a system binary (see [`docker/entrypoint.sh`](docker/entrypoint.sh)).
3. **kitchen-dokken** uses the **host** Docker API (mounted socket) to create
   sibling containers (privileged, systemd `pid_one_command` per
   [`kitchen.yml`](kitchen.yml)).

---

## Dependency management

[`cookbooks/example/Policyfile.rb`](cookbooks/example/Policyfile.rb) demonstrates
Policyfile pins for reproducible converges. To try it, point Kitchen at that
policy instead of `run_list` (see Chef docs for `policyfile` provisioner
options). **Berkshelf** is in the Gemfile if you prefer a `Berksfile`.

---

## Optional: Ruby on the host

If you already have Ruby **3.3+** and Bundler:

```bash
cd test-env/chef
bundle install
bundle exec cookstyle cookbooks
bundle exec rspec cookbooks
bundle exec kitchen verify
```

Install **yamllint**, **shellcheck**, and **hadolint** yourself if you want
parity with the Docker runner.

---

## Adding your own cookbooks

1. Place the cookbook under `cookbooks/<name>/`.
2. Edit [`kitchen.yml`](kitchen.yml): add or change a suite `run_list` to
   `recipe[<name>::default]` (or another recipe).
3. Add **ChefSpec** under `cookbooks/<name>/spec/unit/recipes/` and **InSpec**
   under `cookbooks/<name>/test/integration/<suite>/`.
