# MikroTik script tests (RouterOS 7.24.1)

Integration tests that run **real RouterOS CHR 7.24.1** in QEMU inside Docker and
exercise every `*.lua` in `../`. Two services run side by side:

- `chr` — Alpine + QEMU + the official CHR 7.24.1 disk (talks to host on
  `127.0.0.1:8728` for ad‑hoc inspection).
- `tester` — Python + `RouterOS-api` + `pytest`. Talks to `chr` on the Docker
  network and runs the test suite. **No host Python is required.**

## When it runs in CI

Nightly at 03:37 UTC, on demand, and on any pull request touching `mikrotik/`,
`run-tests.sh`, or `.github/workflows/chr.yml`. The path filter is the point:
booting a router costs minutes, and it should cost them only where a real
router is the one thing that can answer the question. A nightly run cannot
answer it for a change under review, because by the time it fires the change
has usually merged.

## Requirements

- Docker (with the `compose` v2 plugin). Tested on Docker Desktop on macOS and
  on Docker Engine on Linux.
- On Apple Silicon: CHR is x86_64, so the `chr` service is pinned to
  `linux/amd64` and runs through Rosetta + QEMU TCG. First boot can take
  several minutes. The effective ceiling is the healthcheck's, 20 minutes;
  `run.sh --wait-timeout` defaults to 1800 s and never binds first.
- Hardware acceleration needs no edit. `run.sh` layers `docker-compose.kvm.yml`
  on automatically when `/dev/kvm` is present and readable and writable, which
  is ~10x faster and is what Linux CI gets. The device is kept out of
  `docker-compose.yml` because compose fails hard on a device that does not
  exist, which would break every macOS and Docker Desktop developer. Set
  `CHR_KVM=0` to force it off.

## Run

From anywhere in the repo:

```bash
./mikrotik/tests/run.sh
```

That builds both images, brings `chr` up, waits for the API healthcheck,
runs `pytest` inside `tester`, and tears the stack down. To pass extra args
to pytest:

```bash
./mikrotik/tests/run.sh -k version_matches -vv
```

The checked-in version lives in `routeros-version.env`. To test a candidate
without changing tracked files, override it for one run — and override the
digest with it:

```bash
ROUTEROS_VERSION=7.24.1 \
ROUTEROS_SHA256=<digest of that image> ./mikrotik/tests/run.sh
```

`ROUTEROS_SHA256` falls back to the pinned digest, which belongs to the pinned
version, so overriding the version alone fails the image build on a checksum
mismatch rather than testing the candidate. `routeros_version.py record-hash`
prints the digest for a version. The digest is mandatory and an empty one is
fatal: the CHR image boots as a kernel with this repository mounted, so it is
never downloaded without an integrity check.

`EXPECT_ROUTEROS_VERSION` follows `ROUTEROS_VERSION` automatically, so the
suite proves that the requested image is the image that actually booted.

To keep `chr` running between iterations (e.g. while debugging tests):

```bash
KEEP_CHR=1 ./mikrotik/tests/run.sh
# then iterate quickly:
docker compose --env-file mikrotik/tests/routeros-version.env \
  -f mikrotik/tests/docker-compose.yml run --rm tester -k some_test
# stop when done:
docker compose --env-file mikrotik/tests/routeros-version.env \
  -f mikrotik/tests/docker-compose.yml down -v
```

Manual flow (if you don't want the wrapper):

```bash
cd mikrotik/tests
set -a
. ./routeros-version.env
set +a
export EXPECT_ROUTEROS_VERSION="$ROUTEROS_VERSION"
docker compose build
docker compose up -d --wait --wait-timeout 1800 chr
docker compose run --rm tester
docker compose down -v
```

## What is tested

1. **Version** — `/system resource` `version` starts with the exact requested
   release (a patch suffix is accepted only when the requested version omits it).
2. **Source acceptance** — every `mikrotik/*.lua` is added as a
   `/system script` and removed. RouterOS rejects malformed source at `add`
   time, so this catches syntax issues against the live 7.24.1 parser.
3. **Safe execution** — `wan_failover_notify`, `health_check`, and
   `detect_internet` are loaded under their production names and executed.
   `tg_send` is replaced with a **stub** for the test session that records
   the message text but does not call Telegram, so tests do not depend on
   external network reachability.
4. **Backup behaviour** — `backup` is run and its output inspected: the pair it
   writes carries the router's own date and the installed version, and a
   seeded older generation is gone afterwards. The decoy matters — two runs on
   the same day at the same version produce the same filename, so the second
   overwrites the first and deletes nothing, which would pass a naive test
   while proving nothing about retention.
5. **Update-check failure path** — `update_check` is run with
   `UPDATE_CHECK_MAX_WAIT=0`, which skips its poll loop and lands it on the
   timeout path whether or not the CHR can reach MikroTik. The stub's recorded
   message must say the check failed, and must contain no malformed percent
   escape: the text is posted URL-encoded, so a bare `%` is a defect that
   otherwise only shows up as a mangled Telegram message.

Both of the last two drive the script from `/system scheduler`, which is how it
runs on a real router. That is forced rather than chosen: on RouterOS 7.24.1
CHR both `/system script run` and `:parse` refuse any source declaring a
`:global` whose name contains an underscore, reporting "expected end of
command" at the underscore — and that covers most of this package. The suite
used to attribute this to QEMU/TCG emulation; that attribution is wrong. The
identical failure was measured with `/dev/kvm` handed to the container: same
count, same column. The scheduler is the one execution path not blocked by it.

`reboot-and-flush` (reboots the VM), `change_WIFI_pw` (touches wireless
profiles), and `tg_send` itself are intentionally **not executed** — only their
`add → remove` parse step runs. `update_check` is executed only on its timeout
path; the branch that reports an available upgrade needs an update server
saying so, which is not something a test can arrange.

## Environment

| Variable | Default | Meaning |
| --- | --- | --- |
| `ROUTEROS_VERSION` | value in `routeros-version.env` | CHR version to download and image tag |
| `ROUTEROS_SHA256` | value in `routeros-version.env` | SHA-256 of that image. Mandatory; an empty or malformed value exits `1` |
| `CHR_KVM` | `1` | Set `0` to refuse hardware acceleration even where `/dev/kvm` is usable |
| `ROUTEROS_HOST` | `chr` (in tester), `127.0.0.1` (host) | API host |
| `ROUTEROS_PORT` | `8728` | API port |
| `ROUTEROS_USER` | `admin` | API user |
| `ROUTEROS_PASSWORD` | empty | API password (default CHR has none) |
| `ROUTEROS_WAIT_SEC` | `180` | API readiness budget after `chr` is healthy |
| `EXPECT_ROUTEROS_VERSION` | `ROUTEROS_VERSION` | Version expected from `/system/resource` |
| `KEEP_CHR` | `0` | If `1`, `run.sh` leaves CHR running on exit |
| `CHR_MEM_MB` | `512` | RAM passed to QEMU (`-m`) |

## Troubleshooting

- **`Ports already in use on 127.0.0.1: 8728…`** — another local process is
  listening; stop it or change the host port mapping in `docker-compose.yml`.
- **Healthcheck timeout / `up --wait` failed** — under TCG nested emulation
  on Apple Silicon, first boot can be slow. The healthcheck retries for ~20
  minutes; if it still fails, check `docker compose logs chr` for QEMU
  errors. `run.sh` auto-dumps the last 200 log lines on failure.
- **API login fails** — if you previously set a password on the CHR via SSH,
  pass `ROUTEROS_PASSWORD=…` to `run.sh`.
- **macOS Docker Desktop slow** — enable Rosetta in Docker Desktop settings
  (Settings → General → "Use Rosetta for x86/amd64 emulation on Apple Silicon").

## Release checks and version bumps

`routeros_version.py` reads MikroTik's official stable or long-term RSS feed,
validates the release number, and confirms that the matching CHR VDI archive is
available. Its `check` command does not modify files:

```bash
python3 mikrotik/tests/routeros_version.py check
python3 mikrotik/tests/routeros_version.py check --channel long-term
python3 mikrotik/tests/routeros_version.py check --version 7.24.1
```

The `RouterOS version check` GitHub Actions workflow runs every Monday and
Thursday at 04:19 UTC and can also be started manually. When it finds a newer
stable release it boots that candidate in Docker first. Only a passing candidate is
written to `routeros-version.env`, propagated through the documentation, and
proposed in a `chore/routeros-VERSION` pull request. `check_only` runs the same
test without creating a branch or pull request. The canonical pin follows the
stable channel; select both `long-term` and `check_only` to compatibility-test a
long-term release without replacing that pin. The workflow rejects a long-term
run that is not check-only instead of silently treating an older release as the
current target.

## License

CHR is a MikroTik product; downloads happen at build time directly from
MikroTik. Use per [CHR licensing](https://help.mikrotik.com/docs/display/ROS/Cloud+Hosted+Router).

## See also

- [`../README.md`](../README.md) — RouterOS runbook, policies, and scheduler hints.
- [`../../macos-initial-setup/README.md`](../../macos-initial-setup/README.md#development--docker-checks) — **macOS** setup scripts: Docker-based `bash`/`shellcheck` checks (separate from this CHR test stack).
- [Repository root `README.md`](../../README.md#testing-docker) — overview of both Docker test paths.

## Credits

The QEMU‑in‑Docker pattern (Alpine + official VDI → qcow2 + user networking)
follows [tikoci/restraml](https://github.com/tikoci/restraml).
