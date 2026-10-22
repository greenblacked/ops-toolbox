- `macos-initial-setup/net_doctor.sh` is the macOS counterpart of
  `linux/net_doctor.sh` for the moment the network is wrong: interfaces, the
  default route, the primary resolver and every split-DNS resolver a VPN
  installs, whether the Mac's own hostname resolves, a system proxy that
  browsers use and `curl`, `git` and `brew` do not, connected VPN services
  and tunnels, `/etc/hosts` overrides and listening sockets. It changes
  nothing, names proxy variables without printing them, and contacts the
  network only for an explicit `--probe HOST[:PORT]`, which also follows
  an IPv6-only (AAAA) answer.
