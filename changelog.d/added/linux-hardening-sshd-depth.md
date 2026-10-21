- `linux/hardening_audit.sh` grades a dozen more sshd settings in its `ssh`
  group: `MaxAuthTries`, X11, agent and TCP forwarding, `LoginGraceTime`, the
  client-alive idle window (interval times count), `PermitUserEnvironment`, host-based auth,
  `IgnoreRhosts`, public-key auth and tunnels, each against the OpenSSH
  default when it is not set. As root it also reads the effective cipher,
  MAC, key exchange and host key lists from `sshd -T` and names the weak
  ones, with the removal line to add. The group names, flags and exit codes
  are unchanged.
