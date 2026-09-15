- `status.sh` and `workstation_doctor.sh` reported System Integrity Protection
  as enabled on a machine where it was partially disabled. `csrutil status`
  answers `status: unknown (Custom Configuration)` when individual protections
  are turned off and then lists them — and that list contains
  `Kext Signing: enabled`. Both readers matched a bare `enabled` anywhere in
  the block, found that line, and called the machine green. `status.sh` went
  further and exited 0, so its security section passed a Mac with filesystem
  protections off. Both now anchor on `status: `, as `stay_fresh.sh`'s
  `sip_status()` and `hardening_audit.sh` already did — the comment in
  `sip_status()` names this exact failure ("on a machine with a custom
  configuration it answers 'unknown'. All of those used to read as 'SIP is
  off'"), so two of the four copies were hardened and two were not. A custom
  configuration is now reported as partially disabled, which is a warning in
  both scripts. `workstation_doctor.sh` also reads `csrutil status` once
  instead of up to three times.
