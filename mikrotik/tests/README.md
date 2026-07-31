# MikroTik script tests (RouterOS 7.22)

Integration tests that run **real RouterOS CHR 7.22** in QEMU inside Docker and
exercise every `*.lua` in `../`. Two services run side by side:

- `chr` — Alpine + QEMU + the official CHR 7.22 disk (talks to host on
  `127.0.0.1:8728` for ad‑hoc inspection).
- `tester` — Python + `RouterOS-api` + `pytest`. Talks to `chr` on the Docker
  network and runs the test suite. **No host Python is required.**

## Requirements

- Docker (with the `compose` v2 plugin). Tested on Docker Desktop on macOS and
  on Docker Engine on Linux.
- On Apple Silicon: CHR is x86_64, so the `chr` service is pinned to
  `linux/amd64` and runs through Rosetta + QEMU TCG. First boot can take
  several minutes — the harness waits up to 30 minutes by default.
- On Linux CI, uncomment `devices: [/dev/kvm]` in `docker-compose.yml` for
  ~10x faster boot.

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

To keep `chr` running between iterations (e.g. while debugging tests):

```bash
KEEP_CHR=1 ./mikrotik/tests/run.sh
# then iterate quickly:
docker compose -f mikrotik/tests/docker-compose.yml run --rm tester -k some_test
# stop when done:
docker compose -f mikrotik/tests/docker-compose.yml down -v
```

Manual flow (if you don't want the wrapper):

```bash
cd mikrotik/tests
docker compose build
docker compose up -d --wait --wait-timeout 1800 chr
docker compose run --rm tester
docker compose down -v
```

## What is tested

1. **Version** — `/system resource` `version` starts with `7.22` (so `7.22.1`
   passes but `7.221` does not).
2. **Source acceptance** — every `mikrotik/*.lua` is added as a
   `/system script` and removed. RouterOS rejects malformed source at `add`
   time, so this catches syntax issues against the live 7.22 parser.
3. **Safe execution** — `wan_failover_notify`, `health_check`, and
   `detect_internet` are loaded under their production names and executed.
   `tg_send` is replaced with a **stub** for the test session that records
   the message text but does not call Telegram, so tests do not depend on
   external network reachability.

`reboot-and-flush` (reboots the VM), `update_check` (10s sleep + online
update probe), `change_WIFI_pw` (touches wireless profiles), `backup`
(creates files, sends notifications), and `tg_send` itself are intentionally
**not executed** — only their `add → remove` parse step runs.

## Environment

| Variable | Default | Meaning |
| --- | --- | --- |
| `ROUTEROS_VERSION` | `7.22` | CHR version to download (also used for image tag) |
| `ROUTEROS_HOST` | `chr` (in tester), `127.0.0.1` (host) | API host |
| `ROUTEROS_PORT` | `8728` | API port |
| `ROUTEROS_USER` | `admin` | API user |
| `ROUTEROS_PASSWORD` | empty | API password (default CHR has none) |
| `ROUTEROS_WAIT_SEC` | `180` | API readiness budget after `chr` is healthy |
| `EXPECT_ROUTEROS_VERSION` | `7.22` | Major.minor expected from `/system/resource` |
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
