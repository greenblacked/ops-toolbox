- `linux/listen_audit.sh` says which process owns each listening port and
  whether it answers on loopback or to the network, folding IPv4/IPv6 twins
  into one row. `--print` writes the public listeners to stdout as a stable,
  dateless baseline, and `--baseline` or `--allow` compares the live set with
  it, so a new listener exits 1 from cron and an expected one that is gone
  is a warning (`--fail-on any` fails on that too). It runs only `ss` and
  never writes the baseline itself.
