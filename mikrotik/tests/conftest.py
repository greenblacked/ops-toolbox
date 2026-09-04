from __future__ import annotations

import contextlib
import os
import time
from collections.abc import Iterator
from typing import Any

import pytest
import routeros_api
from routeros_api import exceptions as ros_exc

# Test-owned scripts on the router. Anything matching this prefix is fair game to
# remove — the tests own the namespace.
TEST_SCRIPT_PREFIX = "pu_ut_"
# Names the production scripts expect to call by name. We put a stub here for the duration
# of the session so running scripts that depend on tg_send doesn't try real HTTP requests.
TG_SEND_NAME = "tg_send"
TG_SEND_STUB_SOURCE = (
    ":global pu_TG_LAST_MESSAGE;\n"
    ":set pu_TG_LAST_MESSAGE $MessageText;\n"
    ":log info (\"pu_ut tg_send STUB: \" . $MessageText);\n"
)


def _connect_pool() -> routeros_api.RouterOsApiPool:
    host = os.environ.get("ROUTEROS_HOST", "127.0.0.1")
    port = int(os.environ.get("ROUTEROS_PORT", "8728"))
    user = os.environ.get("ROUTEROS_USER", "admin")
    password = os.environ.get("ROUTEROS_PASSWORD", "")
    pool = routeros_api.RouterOsApiPool(
        host,
        username=user,
        password=password,
        port=port,
        plaintext_login=True,
        use_ssl=False,
    )
    pool.set_timeout(20)
    pool.get_api()
    return pool


@pytest.fixture(scope="session")
def ros_pool() -> Iterator[routeros_api.RouterOsApiPool]:
    last: BaseException | None = None
    pool: routeros_api.RouterOsApiPool | None = None
    for attempt in range(1, 6):
        try:
            pool = _connect_pool()
            break
        except (ros_exc.RouterOsApiError, ros_exc.RouterOsApiConnectionError, OSError) as e:
            last = e
            time.sleep(2 * attempt)
    if pool is None:
        raise RuntimeError(f"could not connect to RouterOS API: {last!r}")
    try:
        yield pool
    finally:
        with contextlib.suppress(Exception):
            pool.disconnect()


@pytest.fixture(scope="session")
def api(ros_pool: routeros_api.RouterOsApiPool) -> Any:
    return ros_pool.get_api()


def _row_id(row: dict) -> str:
    for key in (".id", b".id", "id", b"id"):
        if key in row:
            v = row[key]
            return v.decode() if isinstance(v, bytes) else str(v)
    raise KeyError(".id missing in row %r" % (row,))


def _row_str(row: dict, key: str) -> str:
    for k in (key, key.encode()):
        if k in row:
            v = row[k]
            return v.decode() if isinstance(v, bytes) else str(v)
    return ""


def _remove_named_scripts(api: Any, predicate) -> int:
    res = api.get_binary_resource("/system/script")
    rows = list(res.get())
    removed = 0
    for row in rows:
        name = _row_str(row, "name")
        if predicate(name):
            try:
                res.call("remove", {".id": _row_id(row)})
                removed += 1
            except ros_exc.RouterOsApiError:
                pass
    return removed


# Scripts that tests install under their production names (so :parse [/system
# script get NAME] works). These are removed before and after the test session
# in case a previous run was interrupted.
_PRODUCTION_NAMED_TEST_SCRIPTS = {
    "wan_failover_notify",
    "health_check",
    "detect_internet",
    "dhcp_lease_watch",
    "firewall_drift",
    "firewall_drift_baseline",
    "mac_allowlist_dhcp",
    "brute_force_block",
    "rogue_dns_check",
    "backup",
    "update_check",
}

# backup.lua writes into /file and, with RemovePrevious on, deletes what it
# finds there. Both halves are what the tests assert on, so the namespace is
# cleared at session boundaries the same way the script namespace is.
BACKUP_FILE_PREFIX = "backup-"

# Globals tests touch via /system/script/environment. Cleaned at session
# boundaries to avoid leakage between runs (RouterOS keeps :globals across
# scheduler runs within an uptime session).
_TEST_OWNED_GLOBALS = (
    "pu_TG_LAST_MESSAGE",
    "FW_BASELINE",
    "DHCP_KNOWN_MACS",
    "DHCP_PREV_LEASE_COUNT",
    "DHCP_CHURN_FLAG",
    "DHCP_DUPS_FLAG",
    "MAC_ALLOWLIST",
    "MACALLOW_LAST_FLAG",
    "BF_MAX_FAILURES",
    "BF_SEEN_LINES",
    "DNS_EXPECTED",
    "DNS_ALLOWED_RESOLVERS",
    "RDNS_LAST_FLAG",
    "BACKUP_PASSWORD",
    "BACKUP_REMOVE_PREVIOUS",
    "UPDATE_CHECK_BACKUP",
    "UPDATE_CHECK_MAX_WAIT",
    "UPDATE_CHECK_NOTIFY_FAILURE",
)


def _remove_test_schedulers(api: Any) -> None:
    """Tests drive scripts from the scheduler, because the API's own run path
    refuses any source declaring an underscore :global on this CHR. An entry
    left behind by an interrupted run would keep firing for the whole session."""
    res = api.get_binary_resource("/system/scheduler")
    for row in list(res.get()):
        if _row_str(row, "name").startswith(TEST_SCRIPT_PREFIX):
            with contextlib.suppress(ros_exc.RouterOsApiError):
                res.call("remove", {".id": _row_id(row)})


def _remove_backup_files(api: Any) -> None:
    res = api.get_binary_resource("/file")
    for row in list(res.get()):
        if _row_str(row, "name").startswith(BACKUP_FILE_PREFIX):
            with contextlib.suppress(ros_exc.RouterOsApiError):
                res.call("remove", {".id": _row_id(row)})


def _remove_globals(api: Any, names) -> None:
    res = api.get_binary_resource("/system/script/environment")
    rows = list(res.get())
    for row in rows:
        if _row_str(row, "name") in names:
            with contextlib.suppress(ros_exc.RouterOsApiError):
                res.call("remove", {".id": _row_id(row)})


@pytest.fixture(scope="session", autouse=True)
def _clean_router_state(api: Any) -> Iterator[None]:
    """Wipe any leftover test scripts/globals and install the tg_send stub for the session."""
    _remove_named_scripts(
        api,
        lambda n: n.startswith(TEST_SCRIPT_PREFIX)
        or n in ({TG_SEND_NAME} | _PRODUCTION_NAMED_TEST_SCRIPTS),
    )
    _remove_test_schedulers(api)
    _remove_globals(api, _TEST_OWNED_GLOBALS)
    _remove_backup_files(api)
    api.get_binary_resource("/system/script").call(
        "add",
        {
            "name": TG_SEND_NAME.encode("utf-8"),
            "source": TG_SEND_STUB_SOURCE.encode("utf-8"),
        },
    )
    try:
        yield
    finally:
        _remove_named_scripts(
            api,
            lambda n: n.startswith(TEST_SCRIPT_PREFIX)
            or n in ({TG_SEND_NAME} | _PRODUCTION_NAMED_TEST_SCRIPTS),
        )
        _remove_test_schedulers(api)
        _remove_globals(api, _TEST_OWNED_GLOBALS)
        _remove_backup_files(api)


@pytest.fixture
def script_resource(api: Any) -> Any:
    return api.get_binary_resource("/system/script")
