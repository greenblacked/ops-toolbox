# RouterOS 7.25 on hAP ax2: candidate validation

**Status:** Lab candidate, not approval to upgrade the production router.  
**Last reviewed:** 2026-10-24  
**Baseline:** last user-reported installed version 7.24.5 stable (not remotely verified).  
**Test branch:** `chr/test-routeros-7.25`.

## Platform compatibility

MikroTik documents the hAP ax2 (C52iG-5HaxD2HaxD-TC) as an ARM64
IPQ-6010 device with QCN-5052 2.4 and 5 GHz radios, using the
`wifi-qcom` package. RouterOS v7 is supported, so **7.25 is an
applicable release**, but its CHR images are not a substitute for physical
ARM64 + Wi-Fi hardware testing.

MikroTik's [7.25 stable changelog](https://forum.mikrotik.com/t/7-25-stable-is-released/273987)
(2026-10-23 release, 2026-10-22 notes) includes fixes for SAE cached PMKs,
`wifi-qcom` roaming, bridge forwarding and IPv6 snooping, and DNS. A
[CAPsMAN + reselect-interval user report](https://forum.mikrotik.com/t/7-25-stable-is-released/273987/7)
describes dynamic Wi-Fi interfaces being recreated in CAPsMAN deployments,
including one with an hAP ax2 as a managed CAP; removing `reselect-interval`
restored operation in reported configurations. This is a credible
configuration-specific regression, not proof that a standalone hAP ax2
is affected. Additional reports of IPv6 DHCPv6 prefix/source-selection
problems in 7.25 warrant verification if IPv6 is enabled.

Hardware reference: [MikroTik hAP ax2 manual](https://manual.mikrotik.com/hardware/hap-ax-2/).

## CHR integration: what it proves

On this branch, `mikrotik/tests/routeros-version.env` pins CHR 7.25
and the matching ZIP digest. A push triggers the existing
[RouterOS CHR workflow](../../.github/workflows/chr.yml).
It downloads the CHR image **from MikroTik**, verifies SHA-256 before
booting QEMU, checks the runtime version, loads every repository RouterOS
script, and exercises the suite's safe scripted paths. No credentials or
network routes to the physical hAP ax2 are involved.

**Important:** CHR is x86. Passing does **not** establish ARM64 boot,
`wifi-qcom` package/driver behavior, WPA3 association, radio regulatory
behavior, physical IPQ-6010 switch-chip forwarding, ether3 management,
or RouterBOOT compatibility. Failed/xfail script tests must be classified
individually. In particular, the known 7.24.5 underscore-variable parser
failure cannot automatically be called fixed or unchanged on 7.25.

Local equivalent:

```bash
git switch chr/test-routeros-7.25
./run-tests.sh mikrotik
```

## hAP ax2 physical validation matrix (not performed by this repo)

| Area | Pre-upgrade baseline and post-upgrade acceptance | Stop/rollback if |
| --- | --- | --- |
| Boot/packages | Correct RouterOS 7.25 ARM64 and enabled `wifi-qcom`, normal uptime and no unexpected reboots | Boot loop, missing Wi-Fi package |
| Wired management | ether3 management access and isolated management bridge remain available | Administration lost or guest access to management appears |
| WPA3 management SSID | WPA3-SAE-only hidden SSID associates; management-frame protection unchanged | SSID missing, downgrade in authentication requirements, repeated deauth |
| Wi-Fi clients | Stable 2.4/5 GHz association, DHCP and throughput; watch disconnects and channel reselection | Frequent reconnects, interfaces recreating, unusable Wi-Fi |
| Segmentation | Guest/IoT cannot reach management subnets; trusted traffic still passes; bridge/VLAN state unchanged | Any unexpected cross-segment reachability |
| DNS/DoH | Expected resolver path, DoH validation, DNS enforcement and blocked bypasses unchanged | Leaks, resolution failure, unintended UDP/TCP 53 or DoT access |
| Firewall/NAT | Inbound exposure unchanged and established/related traffic works; verify NAT and WAN access | New open management service, forwarding interruption |
| Script/scheduler | Deployed `core/` script schedules run and notify as previously expected | Production backup/health/update automation fails |
| RouterBOOT | Record current/upgrade firmware before and after; do not separately flash bootloader during OS smoke test | Unexpected firmware mismatch or recovery symptoms |

Read-only inspection commands (only through an **authorized wired management
session**, with no credential export):

```routeros
/system resource print
/system package print
/system routerboard print
/interface wifi print detail
/interface wifi registration-table print
/interface bridge print
/interface bridge port print
/ip service print
/ip dns print
/ip firewall filter print stats
/ip firewall nat print stats
/system scheduler print
/log print where topics~"warning|error|critical|wifi"
```

Save a sanitized baseline report off-device before any actual upgrade.
Do not publish full configuration exports or credentials in CI logs or this
public repository. Back up the router and export its configuration locally,
keep wired ether3 recovery available, use reliable power, and plan for
Netinstall recovery. Do not enable DAI/IPSG or change bridge policy as part
of the firmware smoke test.

## Decision rule

A fully green CHR suite is **necessary for repository script compatibility**,
not sufficient for hAP ax2 production readiness. Real-world reports and a
physical smoke test are separate gates. If any of the above checks fail,
remain on the last working stable release and investigate before any further
firmware or RouterBOOT change.
