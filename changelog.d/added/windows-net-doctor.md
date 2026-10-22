- `windows/setup/net_doctor.ps1` is a read-only network report for Windows,
  the counterpart of `linux/net_doctor.sh`: adapters and what kind each one
  is, the default gateway (with a warning when Wi-Fi and a VPN both carry
  one), DNS servers, the WinINET proxy (a protocol named on one side only
  counts as a mismatch) against `HTTP_PROXY` and git's `http.proxy`, the
  hosts file, and the process behind each listening port. `-Probe HOST` asks
  every configured DNS server separately and makes one TCP connection; proxy
  passwords are masked before anything is printed. With a PAC script
  configured, an environment proxy and WinINET off is reported as
  undetermined, naming the PAC URL, rather than as browsers connecting
  directly.
