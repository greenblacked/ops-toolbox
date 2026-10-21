- `linux/disk_cleanup.sh --include-docker-images` removes tagged container
  images that no container uses and that were created more than `--days` ago
  (creation time, not pull time), through docker and podman, while
  `--include-docker` still prunes only dangling images.
  `--include-snap-revisions` removes the snap revisions snapd keeps marked
  disabled, never the active one. Neither ever prunes volumes, both preview
  with `--dry-run` (the image preview also shows `docker system df`), and the
  snap step is skipped under `--no-sudo`.
