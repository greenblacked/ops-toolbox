# RouterOS compatibility

The MikroTik scripts are tested against a booted RouterOS **CHR** image,
not against a physical router. This page separates test evidence from
device-specific upgrade readiness.

## Current verification

| Signal | Recorded result |
| --- | --- |
| Canonical integration version | **7.25** (`mikrotik/tests/routeros-version.env` in this revision) |
| Most recent candidate tested here | **RouterOS 7.25 stable** |
| Candidate test date | October 24, 2026 |
| CHR integration result | **71 passed, 10 expected failures, 7 warnings**, no unexpected failures |
| Candidate branch | [`chr/test-routeros-7.25`](https://github.com/greenblacked/ops-toolbox/tree/chr/test-routeros-7.25) |
| Reproducible evidence | [Successful RouterOS 7.25 CHR run](https://github.com/greenblacked/ops-toolbox/actions/runs/40087017702) |

!!! report "What is actually validated"
    CI verifies the downloaded image checksum, boots RouterOS CHR in QEMU,
    validates the requested running version, loads the repository's RouterOS
    scripts and exercises selected safe execution paths. Expected failures
    are still known limitations, **not** passing behavior.

!!! warning "Hardware compatibility is a separate gate"
    CHR is an x86 virtual router. It cannot verify ARM64 startup,
    `wifi-qcom` Wi-Fi drivers, WPA3 association, IPQ-6010 hardware
    forwarding, Ethernet isolation or RouterBOOT on an hAP ax2.

The values above are a **recorded test snapshot**, not live telemetry from a
home router and not a claim that the page is continuously updated. For
newer candidates or reruns, use
[RouterOS version-check workflow](https://github.com/greenblacked/ops-toolbox/actions/workflows/routeros-version.yml)
and the [CHR integration runs](https://github.com/greenblacked/ops-toolbox/actions/workflows/chr.yml).
The repository's release watcher proposes a reviewed pin bump after a successful
candidate test. A green workflow does **not** automatically approve firmware
installation or prove physical device readiness.

## hAP ax2 upgrade checks

On a real hAP ax2, confirm the following **before and after** a planned
maintenance-window upgrade. The physical checks are not performed by
the repository CI suite.

| Area | Acceptance criterion |
| --- | --- |
| Recovery | Verified off-device backup/export, stable power and wired admin path on ether3 |
| Hardware | ARM64 package and `wifi-qcom` present, no unexpected reboots |
| Management | WPA3-only management SSID and isolated management bridge still work |
| Wi-Fi | Stable 2.4/5 GHz association, DHCP, roaming and channel behavior |
| Segmentation | Guest/IoT isolation and bridge/VLAN behavior unchanged |
| DNS | Filtering, enforced DNS and DoH validation still work without leaks |
| Firewall/NAT | Expected traffic passes and no new management exposure appears |
| Automation | Deployed scripts and scheduler runs still behave as expected |
| RouterBOOT | Firmware versions checked separately; do not bundle changes into initial smoke test |

Relevant RouterOS read-only commands, run through an **authorized wired
management session**:

```routeros
/system resource print
/system package print
/system routerboard print
/interface wifi print detail
/interface wifi registration-table print
/interface bridge port print
/ip service print
/ip dns print
/system scheduler print
/log print where topics~"warning|error|critical|wifi"
```

Never publish full `/export` output or secrets in a public issue or CI log.
If Wi-Fi stability, management reachability, segmentation or DNS enforcement
regresses, keep or restore the previously working stable version using the
prepared recovery path. Do not deploy directly from this documentation site.

## Release and test references

- [Official MikroTik RouterOS changelogs](https://mikrotik.com/download/changelogs)
- [Official MikroTik security advisories](https://mikrotik.com/supportsec)
- [Repository RouterOS integration tests](https://github.com/greenblacked/ops-toolbox/tree/master/mikrotik/tests)
- [Open compatibility and release work](https://github.com/greenblacked/ops-toolbox/pulls)
