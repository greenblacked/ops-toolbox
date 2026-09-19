# MikroTik security and update reporting

The reporting scripts are intentionally conservative. They report what RouterOS
can actually observe and mark the rest as unknown instead of inferring exposure
from one setting.

## Security checks

`security_check.lua` is read-only. It inspects management services, DNS/DoH,
IPv4/IPv6 input filtering, interface-list/bridge topology, MAC management,
neighbor discovery, Wi-Fi observations, device-mode flagging, default admin,
SNMP and UPnP.

Important boundaries:

- `allow-remote-requests=yes` is valid for a LAN resolver. It is not an
  Internet-open-resolver finding unless network reachability is established.
- An empty `/ip service` source restriction does not prove WAN exposure. The
  input firewall is a separate control.
- The presence of an input drop rule does not prove isolation. Disabled or
  invalid drops are ignored, and rule order/topology still require review.
- `flagged=no` is not proof that a router is uncompromised.
- No example management subnet is applied or recommended automatically.

Optional policy globals are `SecurityManagementNetworks`,
`SecurityManagementList`, and `SecurityManagementWifi`. Leave them unset
rather than copying a sample value.

`SecLastFp` records the last observation. `SecDeliveredFp` records only a
Telegram-acknowledged report. This means a failed send is retried rather than
silently deduplicated.

## Why an update is offered

`backup_update_check.lua` now distinguishes availability from urgency.
A newer RouterOS release is reported as **available for review**, not
automatically **required**.

The default reason says that a newer release exists and that its changelog and
affected/fixed ranges need review. An operator can add a reviewed explanation
for one exact version pair with these globals:

```routeros
:global RouterUpdateInstalled "7.x.y"
:global RouterUpdateTarget "7.x.z"
:global RouterUpdatePriority "next maintenance window"
:global RouterUpdateReason "Reviewed reason for this exact version pair"
:global RouterUpdateSource "https://mikrotik.com/download/changelogs"
```

Allowed priorities are `monitor only`, `next maintenance window`, and
`immediate`. The reason is ignored unless both the installed and target
versions exactly match the current observation. This prevents an old advisory
note from being reused after the router or target release changes.

These globals are trusted operator input. The RouterOS script does not scrape
CVE feeds or prove that the reason is correct. Prefer official MikroTik
changelogs/security advisories when setting them.

## Telegram reliability

`tg_send.lua` validates the HTTPS certificate and now treats a message as
delivered only when Telegram returns JSON with `ok=true`. After three failed
attempts it raises an error so callers can keep the finding pending.

New reporting callers use JSON/plain text to avoid HTML/form-encoding ambiguity;
legacy URL-encoded HTML callers remain supported.

## Validation

Run the offline contract tests:

```bash
python3 -m unittest test-env/python/tests/test_mikrotik_security_reporting_contract.py -v
```

The RouterOS CHR suite remains the runtime parser/execution check. It does not
prove physical hAP ax2 Wi-Fi behavior or real Internet exposure.
