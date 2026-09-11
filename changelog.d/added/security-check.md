- `mikrotik/security_check.lua` is a read-only hardening audit of a
  RouterOS box — the counterpart of `linux/hardening_audit.sh` and
  `macos-initial-setup/hardening_audit.sh`. It grades services listening
  on all addresses, default identity/admin, discovery and MAC-server
  exposure, DNS recursion, SNMP, UPnP, SOCKS, bandwidth-server, and an
  empty IPv6 filter, then Telegrams the scan with the command that would
  close each finding. It never changes router config. No underscored
  `:global` names, so it runs on RouterOS 7.24 where most of the folder
  cannot.
