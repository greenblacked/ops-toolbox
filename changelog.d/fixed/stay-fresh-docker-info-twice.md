- `stay_fresh.sh` probed `docker info` twice, once in preflight and once
  inside the docker step. A daemon that hung on the second probe held the
  run lock for another `--step-timeout` (default 30 minutes). The step now
  trusts preflight for liveness and treats a failed `docker context show`
  as a hard failure, the way the second `docker info` used to.
