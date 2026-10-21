- `linux/container_doctor.sh` grades Docker or Podman containers instead of
  counting them: restart loops, OOM kills, unhealthy healthchecks and failed
  exits with no restart policy; privileged containers and engine socket
  mounts; running containers with no memory limit; `json-file` logs with no
  `max-size` and logs past `--log-warn-mb`; dangling images and floating
  tags. It runs only read-only engine verbs, each under a timeout, prints
  every fix instead of applying it, and reads rather than gates unless
  `--fail-on` says otherwise.
