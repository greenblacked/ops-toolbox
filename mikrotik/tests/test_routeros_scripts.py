from __future__ import annotations

import contextlib
import os
import pathlib
import re
import time
import warnings
from typing import Any

import pytest
from routeros_api import exceptions as ros_exc

MIKROTIK_DIR = pathlib.Path(__file__).resolve().parent.parent
EXPECT_VER = os.environ["EXPECT_ROUTEROS_VERSION"]
SCRIPT_FILES = sorted(p for p in MIKROTIK_DIR.glob("*.lua") if p.is_file())

# Scripts safe to load+run during tests (no reboot, no upstream calls).
RUNNABLE_SCRIPTS = (
    "wan_failover_notify",
    "health_check",
    "detect_internet",
    "dhcp_lease_watch",
    "firewall_drift",
    "firewall_drift_baseline",
    "mac_allowlist_dhcp",
    "security_check",
    # rogue_dns_check is intentionally NOT here: it calls :resolve which depends
    # on upstream DNS reachability from the CHR. Its parse step still runs via
    # test_script_add_remove_roundtrip below.
)

# RouterOS 7.24.1 CHR: /system/script/run uses a parser that rejects '_' in
# :local and :global names ("expected end of command" pointing at the
# underscore). Not a bug in the repo .lua files - the same source is accepted
# by script add and runs from the scheduler.
#
# This was previously attributed to QEMU/TCG emulation. That is wrong, and the
# correction is worth keeping: the identical failure was measured on a runner
# with /dev/kvm handed to the container, same counts, same column. Whatever it
# is, hardware acceleration does not change it.
#
# :parse is not the escape hatch either, though this comment used to say it
# was. It refuses the same names, which is why the tests that need to execute a
# script go through _run_via_scheduler instead.
#
# detect_internet.lua has no :global with '_' in the name, so it can still be
# exercised via /system/script/run on CHR.
XFAIL_CHR_SYSTEM_SCRIPT_RUN_UNDERSCORE = pytest.mark.xfail(
    reason=(
        f"RouterOS {EXPECT_VER} CHR refuses '_' in :local/:global names at "
        "execution time on every path tried: /system/script/run, :parse, and "
        "/system scheduler. script add is fine, so the source is stored intact. "
        "Not a .lua source bug."
    ),
    strict=False,
)


def _run_safe_script_param(script_name: str) -> Any:
    if script_name in ("detect_internet", "security_check"):
        return script_name
    return pytest.param(script_name, marks=XFAIL_CHR_SYSTEM_SCRIPT_RUN_UNDERSCORE)


def _row_id(row: dict) -> str:
    for k in (".id", b".id", "id", b"id"):
        if k in row:
            v = row[k]
            return v.decode() if isinstance(v, bytes) else str(v)
    raise KeyError(".id missing in %r" % (row,))


def _row_str(row: dict, key: str) -> str:
    for k in (key, key.encode()):
        if k in row:
            v = row[k]
            return v.decode() if isinstance(v, bytes) else str(v)
    return ""


def _find_id(resource: Any, name: str) -> str | None:
    for row in resource.get():
        if _row_str(row, "name") == name:
            return _row_id(row)
    return None


def _remove_by_name(resource: Any, name: str) -> None:
    rid = _find_id(resource, name)
    if rid is not None:
        resource.call("remove", {".id": rid})


# A script added through the API carries no policy unless one is given, and an
# on-event script runs with the intersection of its own policy and the
# scheduler entry's. Empty intersects to empty, which RouterOS reports as
# "executing script NAME (not enough permissions)" - the script never runs and
# nothing else says why. /system/script/run does not hit this, because it
# borrows the calling API session's permissions instead.
SCRIPT_POLICY = b"ftp,reboot,read,write,policy,test,password,sniff,sensitive,romon"


def _add_script(resource: Any, name: str, source: str) -> None:
    _remove_by_name(resource, name)
    resource.call(
        "add",
        {
            "name": name.encode("utf-8"),
            "source": source.encode("utf-8"),
            "policy": SCRIPT_POLICY,
        },
    )


def _run_named(api: Any, name: str) -> None:
    res = api.get_binary_resource("/system/script")
    rid = _find_id(res, name)
    assert rid is not None, f"script {name!r} not found"
    res.call("run", {".id": rid})


def _read_global(api: Any, name: str) -> str:
    """Return the value of a :global, or '' if it is unset."""
    res = api.get_binary_resource("/system/script/environment")
    for row in res.get():
        if _row_str(row, "name") == name:
            return _row_str(row, "value")
    return ""


def _unset_global(api: Any, name: str) -> None:
    """Remove a :global from /system script environment, if present."""
    res = api.get_binary_resource("/system/script/environment")
    for row in res.get():
        if _row_str(row, "name") == name:
            with contextlib.suppress(ros_exc.RouterOsApiError):
                res.call("remove", {".id": _row_id(row)})
            return


def _remove_address_list_entries(api: Any, list_name: str) -> None:
    res = api.get_binary_resource("/ip/firewall/address-list")
    for row in res.get():
        if _row_str(row, "list") == list_name:
            with contextlib.suppress(ros_exc.RouterOsApiError):
                res.call("remove", {".id": _row_id(row)})


@pytest.mark.skipif(not SCRIPT_FILES, reason="no .lua files under mikrotik/")
def test_script_files_are_non_empty() -> None:
    for p in SCRIPT_FILES:
        assert p.read_text(encoding="utf-8", errors="strict").strip(), f"empty: {p.name}"


def test_routeros_version_matches(api: Any) -> None:
    rows = list(api.get_binary_resource("/system/resource").get())
    assert rows, "/system resource returned empty"
    ver = _row_str(rows[0], "version")
    assert ver, f"version missing in /system resource row: {rows[0]!r}"
    pattern = rf"^{re.escape(EXPECT_VER)}(\.|\b)"
    assert re.match(pattern, ver), (
        f"expected version starting with {EXPECT_VER!r}, got {ver!r}"
    )


@pytest.mark.parametrize("path", SCRIPT_FILES, ids=[p.stem for p in SCRIPT_FILES])
def test_script_add_remove_roundtrip(
    path: pathlib.Path,
    script_resource: Any,
) -> None:
    """Each repo .lua is added as /system/script (parses on real RouterOS) and removed."""
    name = "pu_ut_" + re.sub(r"[^0-9a-zA-Z_]", "_", path.stem)
    source = path.read_text(encoding="utf-8", errors="replace")
    try:
        _add_script(script_resource, name, source)
        rid = _find_id(script_resource, name)
        assert rid is not None, f"script {name!r} not visible after add"
    finally:
        _remove_by_name(script_resource, name)


@pytest.mark.parametrize(
    "script_name",
    [_run_safe_script_param(n) for n in RUNNABLE_SCRIPTS],
)
def test_run_safe_scripts(api: Any, script_resource: Any, script_name: str) -> None:
    """
    Install each runnable script under its real name (so :parse [/system script get …] works)
    and execute it once. tg_send is already a stub from the session fixture.
    detect_internet writes to /interface detect-internet which exists on CHR.
    """
    src = (MIKROTIK_DIR / f"{script_name}.lua").read_text(encoding="utf-8", errors="replace")
    try:
        _add_script(script_resource, script_name, src)
        try:
            _run_named(api, script_name)
        except ros_exc.RouterOsApiError as e:
            pytest.fail(f"running {script_name!r} on RouterOS failed: {e}")
    finally:
        _remove_by_name(script_resource, script_name)


def test_security_check_sends_scan_report(api: Any, script_resource: Any) -> None:
    """security_check is underscore-free, so /system/script/run actually
    executes it on the 7.24 CHR. The session-wide tg_send stub cannot be
    :parse'd there (its :global has an underscore), so this test installs the
    same underscore-free stub backup_update_check uses, under the name
    security_check calls. A stock CHR has the API on (the suite uses it), so
    the scan must produce a report rather than going silent."""
    src = (MIKROTIK_DIR / "security_check.lua").read_text(encoding="utf-8")
    try:
        _add_script(script_resource, "tg_send", TG_SEND_NEW_STUB_SOURCE)
        _add_script(script_resource, "security_check", src)
        _unset_global(api, "SecLastFp")
        _unset_global(api, "PuTgLastMessage")
        _unset_global(api, "pu_TG_LAST_MESSAGE")

        _run_named(api, "security_check")

        msg = _read_global(api, "PuTgLastMessage")
        assert msg, "security_check did not send a Telegram scan report"
        assert "security scan" in msg, f"expected a scan report, got: {msg!r}"
        fp = _read_global(api, "SecLastFp")
        assert fp, "security_check did not record SecLastFp after the scan"
    finally:
        _add_script(script_resource, "tg_send", SESSION_TG_SEND_STUB_SOURCE)
        _remove_by_name(script_resource, "security_check")
        _unset_global(api, "SecLastFp")
        _unset_global(api, "PuTgLastMessage")
        _unset_global(api, "pu_TG_LAST_MESSAGE")


@XFAIL_CHR_SYSTEM_SCRIPT_RUN_UNDERSCORE
def test_firewall_drift_detects_added_rule(api: Any, script_resource: Any) -> None:
    """End-to-end: baseline a clean firewall, add a rule, second run reports drift."""
    drift_src = (MIKROTIK_DIR / "firewall_drift.lua").read_text(encoding="utf-8")
    baseline_src = (MIKROTIK_DIR / "firewall_drift_baseline.lua").read_text(encoding="utf-8")

    test_rule_id: str | None = None
    try:
        _add_script(script_resource, "firewall_drift", drift_src)
        _add_script(script_resource, "firewall_drift_baseline", baseline_src)

        # Reset state from any previous test in this session.
        _unset_global(api, "FW_BASELINE")
        _unset_global(api, "pu_TG_LAST_MESSAGE")
        _remove_address_list_entries(api, "fw-drift-events")

        _run_named(api, "firewall_drift_baseline")

        # First run = silent baseline.
        _run_named(api, "firewall_drift")
        baseline_msg = _read_global(api, "pu_TG_LAST_MESSAGE")
        assert "drift detected" not in baseline_msg, (
            f"firewall_drift sent an alert on baseline run: {baseline_msg!r}"
        )

        # Add a recognizable filter rule.
        filter_res = api.get_binary_resource("/ip/firewall/filter")
        filter_res.call(
            "add",
            {
                "chain": "forward",
                "action": "accept",
                "comment": "pu_ut_firewall_drift_test",
            },
        )
        for row in filter_res.get():
            if _row_str(row, "comment") == "pu_ut_firewall_drift_test":
                test_rule_id = _row_id(row)
                break
        assert test_rule_id is not None, "could not find inserted test rule"

        _unset_global(api, "pu_TG_LAST_MESSAGE")

        # Second run = drift detected.
        _run_named(api, "firewall_drift")
        msg = _read_global(api, "pu_TG_LAST_MESSAGE")
        assert msg, "firewall_drift did not send any Telegram alert after rule add"
        assert "drift detected" in msg, f"expected drift alert, got: {msg!r}"
        assert "pu_ut_firewall_drift_test" in msg, (
            f"expected the new rule's comment in alert, got: {msg!r}"
        )

        addr_res = api.get_binary_resource("/ip/firewall/address-list")
        markers = [
            r for r in addr_res.get() if _row_str(r, "list") == "fw-drift-events"
        ]
        assert markers, "firewall_drift did not add a marker entry to fw-drift-events"
    finally:
        if test_rule_id is not None:
            with contextlib.suppress(ros_exc.RouterOsApiError):
                api.get_binary_resource("/ip/firewall/filter").call(
                    "remove", {".id": test_rule_id}
                )
        _remove_address_list_entries(api, "fw-drift-events")
        _remove_by_name(script_resource, "firewall_drift")
        _remove_by_name(script_resource, "firewall_drift_baseline")
        _unset_global(api, "FW_BASELINE")
        _unset_global(api, "pu_TG_LAST_MESSAGE")


@XFAIL_CHR_SYSTEM_SCRIPT_RUN_UNDERSCORE
def test_mac_allowlist_dhcp_failsafe_empty_list(api: Any, script_resource: Any) -> None:
    """With MAC_ALLOWLIST empty, the script must do nothing (no alert, no list entry)."""
    src = (MIKROTIK_DIR / "mac_allowlist_dhcp.lua").read_text(encoding="utf-8")
    try:
        _add_script(script_resource, "mac_allowlist_dhcp", src)
        _unset_global(api, "MAC_ALLOWLIST")
        _unset_global(api, "MACALLOW_LAST_FLAG")
        _unset_global(api, "pu_TG_LAST_MESSAGE")
        _remove_address_list_entries(api, "dhcp-unknown")

        _run_named(api, "mac_allowlist_dhcp")

        msg = _read_global(api, "pu_TG_LAST_MESSAGE")
        assert "DHCP MAC allowlist alert" not in msg, (
            f"mac_allowlist_dhcp must be silent with empty allowlist: {msg!r}"
        )
        addr_res = api.get_binary_resource("/ip/firewall/address-list")
        unknowns = [
            r for r in addr_res.get() if _row_str(r, "list") == "dhcp-unknown"
        ]
        assert not unknowns, (
            "mac_allowlist_dhcp must not populate dhcp-unknown when allowlist is empty"
        )
    finally:
        _remove_address_list_entries(api, "dhcp-unknown")
        _remove_by_name(script_resource, "mac_allowlist_dhcp")
        _unset_global(api, "MAC_ALLOWLIST")
        _unset_global(api, "MACALLOW_LAST_FLAG")
        _unset_global(api, "pu_TG_LAST_MESSAGE")


@XFAIL_CHR_SYSTEM_SCRIPT_RUN_UNDERSCORE
def test_brute_force_block_failsafe_zero_threshold(
    api: Any, script_resource: Any
) -> None:
    """With BF_MAX_FAILURES=0 the script must refuse to block anyone."""
    src = (MIKROTIK_DIR / "brute_force_block.lua").read_text(encoding="utf-8")
    try:
        _add_script(script_resource, "brute_force_block", src)
        _unset_global(api, "BF_MAX_FAILURES")
        _unset_global(api, "BF_SEEN_LINES")
        _unset_global(api, "pu_TG_LAST_MESSAGE")
        _remove_address_list_entries(api, "brute-force-block")

        # Set the threshold to 0 the same way an operator would — a :global.
        api.get_binary_resource("/").call(
            "execute",
            {"script": b":global BF_MAX_FAILURES 0"},
        )

        _run_named(api, "brute_force_block")

        msg = _read_global(api, "pu_TG_LAST_MESSAGE")
        assert "brute force blocked" not in msg, (
            f"brute_force_block must be silent when MaxFailures < 1: {msg!r}"
        )
        addr_res = api.get_binary_resource("/ip/firewall/address-list")
        blocked = [
            r for r in addr_res.get() if _row_str(r, "list") == "brute-force-block"
        ]
        assert not blocked, (
            "brute_force_block must not populate brute-force-block when MaxFailures < 1"
        )
    finally:
        _remove_address_list_entries(api, "brute-force-block")
        _remove_by_name(script_resource, "brute_force_block")
        _unset_global(api, "BF_MAX_FAILURES")
        _unset_global(api, "BF_SEEN_LINES")
        _unset_global(api, "pu_TG_LAST_MESSAGE")


@XFAIL_CHR_SYSTEM_SCRIPT_RUN_UNDERSCORE
def test_dhcp_lease_watch_baseline_silent(api: Any, script_resource: Any) -> None:
    """First run on a clean router establishes the baseline silently (no alert)."""
    src = (MIKROTIK_DIR / "dhcp_lease_watch.lua").read_text(encoding="utf-8")
    try:
        _add_script(script_resource, "dhcp_lease_watch", src)
        _unset_global(api, "DHCP_KNOWN_MACS")
        _unset_global(api, "DHCP_PREV_LEASE_COUNT")
        _unset_global(api, "DHCP_CHURN_FLAG")
        _unset_global(api, "DHCP_DUPS_FLAG")
        _unset_global(api, "pu_TG_LAST_MESSAGE")
        _remove_address_list_entries(api, "dhcp-watch-new")

        _run_named(api, "dhcp_lease_watch")

        msg = _read_global(api, "pu_TG_LAST_MESSAGE")
        assert "DHCP lease watch alert" not in msg, (
            f"baseline run should be silent, got: {msg!r}"
        )
        addr_res = api.get_binary_resource("/ip/firewall/address-list")
        watch = [
            r for r in addr_res.get() if _row_str(r, "list") == "dhcp-watch-new"
        ]
        assert not watch, (
            "baseline run must not populate dhcp-watch-new"
        )
    finally:
        _remove_address_list_entries(api, "dhcp-watch-new")
        _remove_by_name(script_resource, "dhcp_lease_watch")
        _unset_global(api, "DHCP_KNOWN_MACS")
        _unset_global(api, "DHCP_PREV_LEASE_COUNT")
        _unset_global(api, "DHCP_CHURN_FLAG")
        _unset_global(api, "DHCP_DUPS_FLAG")
        _unset_global(api, "pu_TG_LAST_MESSAGE")


# --- backup.lua and update_check.lua ---------------------------------------
#
# Both were parse-only for a long time, which is a weaker claim than it looks:
# adding a script proves RouterOS accepts the source, not that running it does
# what the file says. That gap matters most for exactly these two - backup.lua
# deletes files, and update_check.lua decides whether to tell you to upgrade.
#
# These tests are written to close it and are marked xfail because the platform
# will not let them. Three execution paths were tried and all three refuse a
# :global whose name contains an underscore, which both scripts have:
#
#   /system/script/run   expected end of command, at the underscore
#   :parse               same, reported against the parsed string
#   /system scheduler    same, logged as (scheduler:NAME) ... at the underscore
#
# Ruled out along the way: QEMU (identical under KVM and TCG, same column) and
# permissions (the scheduler first reported "not enough permissions", which was
# an API-added script carrying no policy - fixed, and the refusal underneath it
# is what is left).
#
# They are kept rather than deleted, and kept non-strict to match the rest of
# the suite. If a later RouterOS accepts these names, they start passing and the
# coverage arrives with it; until then the assertions are here, written down,
# rather than being a gap nobody has described.

BACKUP_PREFIX = "backup-"
PARSE_WRAPPER = "pu_ut_parse_wrapper"


def _clear_backup_files(api: Any) -> None:
    res = api.get_binary_resource("/file")
    for row in list(res.get()):
        if _row_str(row, "name").startswith(BACKUP_PREFIX):
            with contextlib.suppress(ros_exc.RouterOsApiError):
                res.call("remove", {".id": _row_id(row)})


def _backup_files(api: Any) -> list[str]:
    res = api.get_binary_resource("/file")
    return sorted(
        n
        for n in (_row_str(r, "name") for r in res.get())
        if n.startswith(BACKUP_PREFIX)
    )


def _wait_for_backup_files(api: Any, count: int, timeout: float = 30.0) -> list[str]:
    """Poll until `count` backup files exist, or give up.

    `/export file=` returns before the file is necessarily on disk, so asserting
    straight after the run is a race that passes on a fast boot and fails on a
    contended runner.
    """
    deadline = time.monotonic() + timeout
    names = _backup_files(api)
    while len(names) < count and time.monotonic() < deadline:
        time.sleep(1)
        names = _backup_files(api)
    return names


SCHEDULER_NAME = "pu_ut_sched"


def _recent_log_lines(api: Any, limit: int = 20) -> list[str]:
    with contextlib.suppress(ros_exc.RouterOsApiError):
        rows = list(api.get_binary_resource("/log").get())
        return [
            f"{_row_str(r, 'topics')}: {_row_str(r, 'message')}" for r in rows[-limit:]
        ]
    return []


def _run_via_scheduler(
    api: Any,
    name: str,
    ready,
    timeout: float = 60.0,
    interval: str = "1s",
) -> None:
    """Run an installed script from the scheduler, and wait for its effect.

    Not a stylistic choice. On RouterOS 7.24.1 CHR both `/system/script/run`
    and `:parse` refuse any source declaring a `:global` whose name contains an
    underscore - "expected end of command" pointing exactly at the underscore -
    which is most of this package. Measured under KVM as well as TCG, so the
    QEMU attribution in XFAIL_CHR_SYSTEM_SCRIPT_RUN_UNDERSCORE does not hold.

    The scheduler is how these scripts run on a real router, so it is both the
    more faithful harness and the one execution path not blocked by that.

    `ready` is polled until it returns true. The entry re-fires every second
    until then, which is safe here because both scripts are idempotent within a
    run: the same date and version produce the same filename, and the same
    failure produces the same message.

    `interval` is the re-fire period. A script that sits in a :delay for longer
    than that gets a second instance started under it every period, which is
    harmless for the quick ones and a pile-up for backup_update_check with its
    fixed 15s wait; that caller passes an interval longer than its own run.
    """
    res = api.get_binary_resource("/system/scheduler")
    _remove_by_name(res, SCHEDULER_NAME)
    res.call(
        "add",
        {
            "name": SCHEDULER_NAME.encode("utf-8"),
            "on-event": name.encode("utf-8"),
            "interval": interval.encode("utf-8"),
            "policy": SCRIPT_POLICY,
        },
    )
    try:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if ready():
                return
            time.sleep(1)
    finally:
        _remove_by_name(res, SCHEDULER_NAME)
    log = "\n".join(_recent_log_lines(api)) or "(router log empty or unreadable)"
    raise AssertionError(f"{name} produced no effect within {timeout:.0f}s\n{log}")


def _set_global_via_scheduler(
    api: Any,
    script_resource: Any,
    name: str,
    literal: str,
) -> None:
    """Set a :global by running a one-line script from the scheduler.

    /system/script/environment cannot create a global no script has declared,
    and declaring one named UPDATE_CHECK_MAX_WAIT hits the underscore refusal
    above - so the declaration has to go through the scheduler like everything
    else here.
    """
    helper = "pu_ut_setglobal"
    _add_script(script_resource, helper, f":global {name} {literal};\n")
    try:
        _run_via_scheduler(
            api, helper, lambda: _read_global(api, name) != "", timeout=30.0
        )
    finally:
        _remove_by_name(script_resource, helper)


def _router_date(api: Any) -> str:
    rows = list(api.get_binary_resource("/system/clock").get())
    assert rows, "/system clock returned empty"
    # backup.lua rewrites '/' to '-' so a non-ISO date-format cannot turn the
    # filename into a path.
    return _row_str(rows[0], "date").replace("/", "-")


@XFAIL_CHR_SYSTEM_SCRIPT_RUN_UNDERSCORE
def test_backup_names_the_pair_by_date_and_version(
    api: Any,
    script_resource: Any,
) -> None:
    """One run leaves a .backup/.rsc pair carrying the date and the version."""
    _clear_backup_files(api)
    src = (MIKROTIK_DIR / "backup.lua").read_text(encoding="utf-8", errors="replace")
    try:
        _add_script(script_resource, "backup", src)
        _run_via_scheduler(api, "backup", lambda: len(_backup_files(api)) >= 2)
        names = _wait_for_backup_files(api, 2)
    finally:
        _remove_by_name(script_resource, "backup")
        _clear_backup_files(api)

    assert len(names) == 2, f"expected a .backup/.rsc pair, got {names}"
    assert sorted(n.rsplit(".", 1)[1] for n in names) == ["backup", "rsc"], names
    stems = {n.rsplit(".", 1)[0] for n in names}
    assert len(stems) == 1, f"pair does not share a stem: {names}"
    stem = stems.pop()

    date = _router_date(api)
    assert date, "router reported no date"
    assert date in stem, f"date {date!r} missing from {stem!r}"
    assert EXPECT_VER in stem, f"version {EXPECT_VER!r} missing from {stem!r}"
    assert "/" not in stem, f"filename would create a directory: {stem!r}"


@XFAIL_CHR_SYSTEM_SCRIPT_RUN_UNDERSCORE
def test_backup_removes_the_previous_generation(
    api: Any,
    script_resource: Any,
) -> None:
    """A second generation replaces the first rather than accumulating.

    Seeded with a decoy rather than by running backup.lua twice: two runs on the
    same day at the same version produce the same filename, so the second
    overwrites the first and deletes nothing. A decoy under an older name is
    what the retention sweep is actually for.
    """
    _clear_backup_files(api)
    stale = "backup-stale-2020-01-01-6.49.10"
    try:
        # No :local or :global at all, so this one can go through the ordinary
        # /system/script/run path.
        decoy = "pu_ut_decoy"
        _add_script(
            script_resource,
            decoy,
            f"/system backup save name={stale} dont-encrypt=yes;\n",
        )
        try:
            _run_named(api, decoy)
        finally:
            _remove_by_name(script_resource, decoy)
        assert _wait_for_backup_files(api, 1), "decoy backup was not created"
        assert f"{stale}.backup" in _backup_files(api)

        src = (MIKROTIK_DIR / "backup.lua").read_text(
            encoding="utf-8", errors="replace"
        )
        _add_script(script_resource, "backup", src)
        _run_via_scheduler(
            api,
            "backup",
            lambda: f"{stale}.backup" not in _backup_files(api),
        )
        names = _wait_for_backup_files(api, 2)
    finally:
        _remove_by_name(script_resource, "backup")
        _clear_backup_files(api)

    assert f"{stale}.backup" not in names, f"previous generation survived: {names}"
    assert len(names) == 2, f"expected exactly the new pair, got {names}"


@XFAIL_CHR_SYSTEM_SCRIPT_RUN_UNDERSCORE
def test_update_check_reports_a_failed_check(
    api: Any,
    script_resource: Any,
) -> None:
    """A check that never reaches a verdict sends a message instead of going quiet.

    UPDATE_CHECK_MAX_WAIT=0 skips the poll loop, so the script reaches its
    timeout path deterministically whether or not the CHR can reach MikroTik.
    It still sits through the 5s settle delay; if this ever fails on the API
    read timeout rather than on an assertion, `check-for-updates once` has
    started blocking, which it is not supposed to do.
    """
    _unset_global(api, "pu_TG_LAST_MESSAGE")
    src = (MIKROTIK_DIR / "update_check.lua").read_text(
        encoding="utf-8", errors="replace"
    )
    try:
        _set_global_via_scheduler(
            api, script_resource, "UPDATE_CHECK_MAX_WAIT", "0"
        )
        _add_script(script_resource, "update_check", src)
        _run_via_scheduler(
            api,
            "update_check",
            lambda: _read_global(api, "pu_TG_LAST_MESSAGE") != "",
        )
    finally:
        _remove_by_name(script_resource, "update_check")
        _unset_global(api, "UPDATE_CHECK_MAX_WAIT")

    message = _read_global(api, "pu_TG_LAST_MESSAGE")
    assert "update check FAILED" in message, f"no failure notice sent: {message!r}"
    # tg_send posts the text URL-encoded, so every % has to introduce a real
    # escape. A bare one is the defect this assertion exists to keep out.
    stray = re.search(r"%(?![0-9A-Fa-f]{2})", message)
    assert stray is None, f"malformed percent escape at {stray.start()}: {message!r}"


# --- what a real RouterOS reports around an update check ---------------------
#
# The update scripts reason about four fields of /system package update and a
# handful of resource readings, and the comments in update_check.lua and
# stay_fresh.lua make claims about how those fields move: latest-version
# survives from the previous check, status holds the old verdict for a moment
# before "checking for updates...", check-for-updates once does not block. The
# two tests below put the observed behaviour into the CI log so those claims can
# be read against a live release rather than remembered.

UPDATE_VERDICTS = ("New version is available", "up to date", "ERROR", "error")


def _row_items(row: dict) -> list[tuple[str, str]]:
    out = []
    for k, v in row.items():
        key = k.decode() if isinstance(k, bytes) else str(k)
        if key == ".id":
            continue
        out.append((key, v.decode() if isinstance(v, bytes) else str(v)))
    return out


def _update_fields(api: Any) -> dict[str, str]:
    rows = list(api.get_binary_resource("/system/package/update").get())
    row = rows[0] if rows else {}
    keys = ("channel", "installed-version", "latest-version", "status")
    return {k: _row_str(row, k) for k in keys}


def _dump_path(api: Any, path: str) -> list[str]:
    try:
        rows = list(api.get_binary_resource(path).get())
    except ros_exc.RouterOsApiError as e:
        return [f"{path}: error: {e}"]
    if not rows:
        return [f"{path}: (no rows)"]
    return [f"{path}: " + ", ".join(f"{k}={v}" for k, v in _row_items(row)) for row in rows]


PROBE_PATHS = (
    "/system/package/update",
    "/system/resource",
    "/system/routerboard",
    "/system/health",
    "/system/license",
    "/system/package",
    "/system/ntp/client",
    "/ip/dns",
    "/system/clock",
)


def test_update_check_probe_records_how_status_moves(api: Any, script_resource: Any) -> None:
    """Trigger a real check and record how status and latest-version move.

    The trail and the field dump go into the warnings summary, which pytest
    prints by default, so the CI log carries what this release actually
    reports. The one assertion is that status reaches a verdict - one of the
    strings the update scripts test for - within 90 seconds. On a runner with
    no route to MikroTik that verdict is an ERROR line, and the trail then
    shows what the failed-check path of backup_update_check.lua will see.
    """
    before = _update_fields(api)
    probe = "pu_ut_update_probe"
    # No :local or :global, so /system/script/run is fine here.
    _add_script(script_resource, probe, "/system package update check-for-updates once;\n")
    trail = [f"before the check: {before}"]
    t0 = time.monotonic()
    settled = False
    try:
        _run_named(api, probe)
        trail.append(f"check-for-updates once returned after {time.monotonic() - t0:.1f}s")
        last: tuple[str, str] | None = None
        while time.monotonic() - t0 < 90:
            fields = _update_fields(api)
            snap = (fields["status"], fields["latest-version"])
            if snap != last:
                trail.append(
                    f"{time.monotonic() - t0:5.1f}s status={snap[0]!r} latest={snap[1]!r}"
                )
                last = snap
            if any(v in fields["status"] for v in UPDATE_VERDICTS):
                settled = True
                break
            time.sleep(2)
    finally:
        _remove_by_name(script_resource, probe)

    dump = [line for path in PROBE_PATHS for line in _dump_path(api, path)]
    warnings.warn("\n".join(["update check probe:", *trail, *dump]), stacklevel=2)
    assert settled, "status reached no verdict within 90s:\n" + "\n".join(trail)


# A Telegram stub whose :global carries no underscore, so a 7.24 CHR can :parse
# it. The session-wide tg_send stub cannot be parsed there, which is why every
# end-to-end run of update_check.lua on the CHR is an xfail; this stub, under
# the name backup_update_check.lua calls by default, is what lets that script
# run for real.
SESSION_TG_SEND_STUB_SOURCE = (
    ":global pu_TG_LAST_MESSAGE;\n"
    ":set pu_TG_LAST_MESSAGE $MessageText;\n"
    ':log info ("pu_ut tg_send STUB: " . $MessageText);\n'
)
TG_SEND_NEW_STUB_SOURCE = (
    ":global PuTgLastMessage;\n"
    ":set PuTgLastMessage $MessageText;\n"
    ':log info ("pu_ut tg_send_new STUB: " . $MessageText);\n'
)


def test_backup_update_check_runs_end_to_end(api: Any, script_resource: Any) -> None:
    """backup_update_check.lua runs on the CHR and sends one of its three messages.

    Whichever outcome the runner's network produces - a newer release, up to
    date, or a failed check - the message has to name it, carry RouterOS's own
    status line and the clock, and contain no bare percent sign. When a newer
    release is offered, the pre-upgrade pair has to exist as well. The message
    goes into the warnings summary so the CI log shows the real rendering.
    """
    _unset_global(api, "PuTgLastMessage")
    _clear_backup_files(api)
    src = (MIKROTIK_DIR / "backup_update_check.lua").read_text(
        encoding="utf-8", errors="replace"
    )
    try:
        _add_script(script_resource, "tg_send_new", TG_SEND_NEW_STUB_SOURCE)
        _add_script(script_resource, "backup_update_check", src)
        # The script sits in a 15s :delay, so re-fire slower than it runs.
        _run_via_scheduler(
            api,
            "backup_update_check",
            lambda: _read_global(api, "PuTgLastMessage") != "",
            timeout=150.0,
            interval="40s",
        )
        message = _read_global(api, "PuTgLastMessage")
        backups = _backup_files(api) if "update is required" in message else []
    finally:
        _remove_by_name(script_resource, "backup_update_check")
        _remove_by_name(script_resource, "tg_send_new")
        _unset_global(api, "PuTgLastMessage")
        _clear_backup_files(api)

    warnings.warn("backup_update_check message:\n" + message, stacklevel=2)
    headlines = (
        "RouterOS update is required.",
        "RouterOS update is not required.",
        "RouterOS update check FAILED.",
    )
    assert any(h in message for h in headlines), f"no known headline: {message!r}"
    assert "Status: <code>" in message, f"status line missing: {message!r}"
    assert "Checked: <code>" in message, f"clock line missing: {message!r}"
    assert "installed packages <code>" in message, f"package size missing: {message!r}"
    stray = re.search(r"%(?![0-9A-Fa-f]{2})", message)
    assert stray is None, f"bare percent at {stray.start()}: {message!r}"
    if "update is required" in message:
        assert len(backups) >= 2, f"newer release offered but no backup pair: {backups}"


# The hostnames the update check talks to. Overridden with static DNS entries
# pointing at the router itself, a check fails fast - connection refused on a
# port nothing listens on - instead of waiting out a timeout, and the failure is
# undone by removing the entries.
UPDATE_HOSTS = ("upgrade.mikrotik.com", "download.mikrotik.com")
PROBE_DNS_COMMENT = "pu_ut probe"


def _await_verdict(api: Any, previous: str, timeout: float = 90.0) -> tuple[list[str], dict]:
    """Poll status until it settles on a verdict that is not the pre-run value.

    A terminal-looking status read straight after check-for-updates can still
    be the previous run's, so a value equal to `previous` only counts once a
    few seconds have passed and it has demonstrably not moved.
    """
    t0 = time.monotonic()
    trail: list[str] = []
    last: tuple[str, str] | None = None
    fields = _update_fields(api)
    while time.monotonic() - t0 < timeout:
        fields = _update_fields(api)
        snap = (fields["status"], fields["latest-version"])
        if snap != last:
            trail.append(f"{time.monotonic() - t0:5.1f}s status={snap[0]!r} latest={snap[1]!r}")
            last = snap
        status = fields["status"]
        moved = status != previous or time.monotonic() - t0 > 5
        if moved and any(v in status for v in UPDATE_VERDICTS):
            break
        time.sleep(1)
    return trail, fields


def _remove_probe_dns_entries(api: Any) -> None:
    res = api.get_binary_resource("/ip/dns/static")
    for row in list(res.get()):
        if _row_str(row, "comment") == PROBE_DNS_COMMENT:
            with contextlib.suppress(ros_exc.RouterOsApiError):
                res.call("remove", {".id": _row_id(row)})
    with contextlib.suppress(ros_exc.RouterOsApiError):
        api.get_binary_resource("/ip/dns/cache").call("flush", {})


def test_a_failed_check_clears_latest_version(api: Any, script_resource: Any) -> None:
    """A check that fails leaves latest-version empty, not stale.

    The update scripts' comments used to say the opposite - that the field
    kept the previous check's answer - and the first version of this test
    asserted that. On 7.24.2 the CHR says: issuing the check clears the field
    at once, a good check refills it in about a second, a failed one leaves it
    empty with an ERROR line in status. Either way the field cannot be the
    verdict, which is why the scripts poll status. The trail and the exact
    ERROR text this release emits go into the warnings summary.
    """
    probe = "pu_ut_update_probe"
    _add_script(script_resource, probe, "/system package update check-for-updates once;\n")
    good_trail: list[str] = []
    bad_trail: list[str] = []
    good: dict = {}
    bad: dict = {}
    try:
        previous = _update_fields(api)["status"]
        _run_named(api, probe)
        good_trail, good = _await_verdict(api, previous)
        if any(e in good["status"] for e in ("ERROR", "error")) or not good["latest-version"]:
            pytest.skip(f"the runner cannot reach the update server: {good}")

        res = api.get_binary_resource("/ip/dns/static")
        for host in UPDATE_HOSTS:
            res.call(
                "add",
                {
                    "name": host.encode("utf-8"),
                    "address": b"127.0.0.1",
                    "comment": PROBE_DNS_COMMENT.encode("utf-8"),
                },
            )
        with contextlib.suppress(ros_exc.RouterOsApiError):
            api.get_binary_resource("/ip/dns/cache").call("flush", {})
        previous = good["status"]
        _run_named(api, probe)
        bad_trail, bad = _await_verdict(api, previous)
    finally:
        _remove_probe_dns_entries(api)
        _remove_by_name(script_resource, probe)

    report = [
        "failed-check probe:",
        "good check:",
        *good_trail,
        "with the hosts overridden:",
        *bad_trail,
    ]
    warnings.warn("\n".join(report), stacklevel=2)
    errored = any(e in bad["status"] for e in ("ERROR", "error"))
    if not errored:
        pytest.skip(f"the override did not make the check fail; status {bad['status']!r}")
    assert good["latest-version"], f"the good check reported no version: {good}"
    assert bad["latest-version"] == "", (
        f"a failed check left latest-version populated on this release: {good} -> {bad}"
    )


def test_backup_update_check_backs_up_when_a_release_is_offered(
    api: Any, script_resource: Any
) -> None:
    """On the development channel the CHR is usually offered a newer build.

    That is the one way to reach the "update is required" path on a router
    pinned to the current stable release without installing anything: the
    script only ever checks, backs up and reports. The channel setting is
    patched in the installed copy, and the router is put back on stable in
    the finally. When the development channel happens to offer nothing newer,
    or the runner cannot reach the server, the test skips and says so.
    """
    _unset_global(api, "PuTgLastMessage")
    _clear_backup_files(api)
    src = (MIKROTIK_DIR / "backup_update_check.lua").read_text(
        encoding="utf-8", errors="replace"
    )
    patched = src.replace(':local updChannel "stable"', ':local updChannel "development"', 1)
    assert patched != src, "the channel setting moved; update this test"
    update = api.get_binary_resource("/system/package/update")
    message = ""
    names: list[str] = []
    try:
        _add_script(script_resource, "tg_send_new", TG_SEND_NEW_STUB_SOURCE)
        _add_script(script_resource, "backup_update_check", patched)
        _run_via_scheduler(
            api,
            "backup_update_check",
            lambda: _read_global(api, "PuTgLastMessage") != "",
            timeout=150.0,
            interval="40s",
        )
        message = _read_global(api, "PuTgLastMessage")
        if "update is required" in message:
            names = _wait_for_backup_files(api, 2)
    finally:
        _remove_by_name(script_resource, "backup_update_check")
        _remove_by_name(script_resource, "tg_send_new")
        _unset_global(api, "PuTgLastMessage")
        _clear_backup_files(api)
        with contextlib.suppress(ros_exc.RouterOsApiError):
            update.call("set", {"channel": b"stable"})

    warnings.warn("backup_update_check on the development channel:\n" + message, stacklevel=2)
    if "update check FAILED" in message:
        pytest.skip(f"the runner cannot reach the update server: {message!r}")
    if "update is not required" in message:
        pytest.skip("the development channel offers nothing newer than the pinned release")

    assert "RouterOS update is required." in message, f"no known headline: {message!r}"
    assert "Status: <code>New version is available" in message, message
    assert len(names) >= 2, f"a release was offered but no backup pair exists: {names}"
    stems = {n.rsplit(".", 1)[0] for n in names}
    assert len(stems) == 1, f"pair does not share a stem: {names}"
    stem = stems.pop()
    assert stem.startswith("backup-") and stem.endswith("-pre-upgrade"), stem
    assert EXPECT_VER in stem, f"installed version {EXPECT_VER!r} missing from {stem!r}"
    assert f"Backup: <code>{stem}</code>" in message, message
    for needle in ("Changelog:", "Packages: <code>routeros", "Reboot impact", "Checked: <code>"):
        assert needle in message, f"{needle!r} missing: {message!r}"
    stray = re.search(r"%(?![0-9A-Fa-f]{2})", message)
    assert stray is None, f"bare percent at {stray.start()}: {message!r}"
