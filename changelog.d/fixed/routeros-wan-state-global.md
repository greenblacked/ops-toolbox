- `wan_failover_notify.lua` runs on RouterOS 7.24 and later again. Its
  `WAN_LAST_STATE` global has an underscore, which the 7.24 parser refuses, so
  the script stopped before logging anything. The state is now `WanLastState`,
  so expect one baseline notification after upgrading; scheduler entries keep
  the same script name. `router_doctor.py` no longer lists the script as
  needing the underscore fallback.
