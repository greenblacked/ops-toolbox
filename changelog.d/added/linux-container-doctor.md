- `linux/container_doctor.sh` grades Docker or Podman containers instead of
  counting them: restart loops, OOM kills, unhealthy healthchecks and failed
  exits with no restart policy or with `on-failure:N` retries used up;
  privileged containers and engine socket mounts; running containers with no
  memory limit; `json-file` logs with no `max-size` and logs past
  `--log-warn-mb`; dangling images and floating tags. It runs only read-only
  engine verbs, each under a timeout, prints every fix instead of applying it,
  and reads rather than gates unless `--fail-on` says otherwise. Each
  container's log cap is read from its own inspected log config; a `max-size`
  in `daemon.json` applies only to containers created after it was set, so it
  does not clear existing ones.
