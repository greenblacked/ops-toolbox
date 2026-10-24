"""Fail-closed preflight for the destructive RouterOS CHR test suite.

This guard does not authorize testing production CHR instances. It prevents
accidental use against any RouterOS endpoint other than this fresh QEMU lab.
The first modification must occur only after every check succeeds.
"""

from __future__ import annotations

import os
import re
from collections.abc import Mapping
from typing import Any

LAB_FLAG = "isolated-qemu-only"
LAB_HOST = "chr"
LAB_PORT = "8728"
LAB_MAC = "52:54:00:5A:02:51"


class UnsafeLabTarget(RuntimeError):
    """The target cannot be proved to be this disposable QEMU lab."""


def _value(row: dict, key: str) -> str:
    value = row.get(key, row.get(key.encode("utf-8"), b""))
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return str(value)


def validate_lab_environment(env: Mapping[str, str]) -> str:
    """Reject unexpected endpoints before opening any API connection."""
    if env.get("OPSTOOLBOX_CHR_LAB") != LAB_FLAG:
        raise UnsafeLabTarget("missing explicit disposable-CHR test flag")
    if env.get("ROUTEROS_HOST") != LAB_HOST or env.get("ROUTEROS_PORT") != LAB_PORT:
        raise UnsafeLabTarget("test target must be Docker service chr:8728")
    version = env.get("EXPECT_ROUTEROS_VERSION", "")
    if not re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", version):
        raise UnsafeLabTarget("missing or invalid expected RouterOS version")
    return version


def assert_disposable_chr(api: Any, env: Mapping[str, str] | None = None) -> None:
    """Read-only verification performed before cleaning/adding any scripts."""
    source = os.environ if env is None else env
    expected = validate_lab_environment(source)

    resources = list(api.get_binary_resource("/system/resource").get())
    if len(resources) != 1:
        raise UnsafeLabTarget("cannot identify the RouterOS system resource")
    info = resources[0]
    if _value(info, "board-name").strip().upper() != "CHR":
        raise UnsafeLabTarget("target board is not CHR")
    if _value(info, "architecture-name").strip().lower() != "x86_64":
        raise UnsafeLabTarget("target architecture is not x86_64 CHR")
    version = _value(info, "version").strip()
    if not (version == expected or version.startswith(expected + " (")):
        raise UnsafeLabTarget(
            f"unexpected CHR version {version!r}; expected {expected!r}"
        )

    ethernet = list(api.get_binary_resource("/interface/ethernet").get())
    if len(ethernet) != 1 or _value(ethernet[0], "mac-address").upper() != LAB_MAC:
        raise UnsafeLabTarget("target does not have the QEMU test NIC identity")

    # A test-owned VM is born empty. Fail instead of destroying an unrelated
    # script, a previous interrupted run, or files on a reused CHR instance.
    scripts = list(api.get_binary_resource("/system/script").get())
    if scripts:
        raise UnsafeLabTarget("CHR contains scripts; reset the disposable lab")

    schedulers = list(api.get_binary_resource("/system/scheduler").get())
    if any(_value(row, "name").startswith("pu_ut_") for row in schedulers):
        raise UnsafeLabTarget("CHR contains test schedulers; reset the lab")

    files = list(api.get_binary_resource("/file").get())
    if any(_value(row, "name").startswith("backup-") for row in files):
        raise UnsafeLabTarget("CHR contains backup files; reset the lab")
