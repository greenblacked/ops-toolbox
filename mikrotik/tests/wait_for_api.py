#!/usr/bin/env python3
"""
Wait until CHR is listening on the API port and accepts a login.

Tunables (env):
  ROUTEROS_HOST            host running CHR (default: chr in docker, 127.0.0.1 outside)
  ROUTEROS_PORT            API port (default: 8728)
  ROUTEROS_USER            user (default: admin)
  ROUTEROS_PASSWORD        password (default: empty)
  ROUTEROS_WAIT_SEC        max wait for full readiness (default: 180s)
"""
from __future__ import annotations

import contextlib
import os
import socket
import sys
import time

import routeros_api
from routeros_api import exceptions as ros_exc

HOST = os.environ.get("ROUTEROS_HOST", "127.0.0.1")
PORT = int(os.environ.get("ROUTEROS_PORT", "8728"))
USER = os.environ.get("ROUTEROS_USER", "admin")
PASSWORD = os.environ.get("ROUTEROS_PASSWORD", "")
WAIT_SEC = int(os.environ.get("ROUTEROS_WAIT_SEC", "180"))


def _now() -> float:
    return time.monotonic()


def _wait_tcp(deadline: float) -> None:
    last: BaseException | None = None
    while _now() < deadline:
        try:
            with socket.create_connection((HOST, PORT), timeout=5):
                return
        except OSError as e:
            last = e
            time.sleep(2)
    raise TimeoutError(f"TCP {HOST}:{PORT} never opened: {last!r}")


def _wait_login(deadline: float) -> None:
    last: BaseException | None = None
    attempts = 0
    while _now() < deadline:
        attempts += 1
        pool = None
        try:
            pool = routeros_api.RouterOsApiPool(
                HOST,
                username=USER,
                password=PASSWORD,
                port=PORT,
                plaintext_login=True,
                use_ssl=False,
            )
            pool.set_timeout(10)
            api = pool.get_api()
            list(api.get_resource("/system/resource").get())
            return
        except (
            ros_exc.RouterOsApiError,
            ros_exc.RouterOsApiConnectionError,
            ros_exc.FatalRouterOsApiError,
            ConnectionError,
            OSError,
        ) as e:
            last = e
            if attempts <= 3 or attempts % 5 == 0:
                print(f"[wait] attempt #{attempts} failed: {e}", flush=True)
            time.sleep(3)
        finally:
            if pool is not None:
                with contextlib.suppress(Exception):
                    pool.disconnect()
    raise TimeoutError(f"API login never succeeded after {attempts} attempts: {last!r}")


def main() -> None:
    started = _now()
    deadline = started + WAIT_SEC
    print(f"[wait] target={HOST}:{PORT} user={USER!r} budget={WAIT_SEC}s", flush=True)
    try:
        _wait_tcp(deadline)
        elapsed = _now() - started
        print(f"[wait] TCP open after {elapsed:.1f}s; logging in…", flush=True)
        _wait_login(deadline)
    except TimeoutError as e:
        print(f"[wait] FAILED: {e}", file=sys.stderr, flush=True)
        sys.exit(1)
    except KeyboardInterrupt:
        print("[wait] interrupted", file=sys.stderr, flush=True)
        sys.exit(130)
    elapsed = _now() - started
    print(f"[wait] RouterOS API ready after {elapsed:.1f}s.", flush=True)


if __name__ == "__main__":
    main()
