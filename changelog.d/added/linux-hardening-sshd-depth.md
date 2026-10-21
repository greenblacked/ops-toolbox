- `linux/hardening_audit.sh` grades a dozen more sshd settings in its `ssh`
  group: `MaxAuthTries`, X11, agent and TCP forwarding, `LoginGraceTime`, the
  client-alive connection-liveness window (interval times count, which drops
  unresponsive clients, not idle users), `ChannelTimeout` as the idle bound
  (OpenSSH 9.2+, reported as info when unset), `PermitUserEnvironment`, host-based auth,
  `IgnoreRhosts`, public-key auth and tunnels, each against the OpenSSH
  default when it is not set. As root it also reads the effective cipher,
  MAC, key exchange and host key lists from `sshd -T` and names the weak
  ones, with the removal line to add. The group names, flags and exit codes
  are unchanged.
