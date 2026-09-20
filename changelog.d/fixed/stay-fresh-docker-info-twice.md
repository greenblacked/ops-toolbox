- `stay_fresh.sh` probed `docker info` twice, once in preflight and once
  inside the docker step. A daemon that hung on the second probe held the
  run lock for another `--step-timeout` (default 30 minutes). The step drops
  the second probe and checks the exit status of `docker system df` instead —
  the size line it prints anyway, and the first call in the step that has to
  reach the daemon. `docker context show`, which the step still runs to find
  out whether the endpoint is local, reads the CLI's own context store and
  never opens the socket, so it cannot tell a live daemon from a dead one: a
  daemon that went away after preflight left each prune to discover that
  separately, warning rather than failing, so the step ended WARN and the run
  exited 0 — and waiting a full `--step-timeout` per command first if the
  daemon hung rather than died.
