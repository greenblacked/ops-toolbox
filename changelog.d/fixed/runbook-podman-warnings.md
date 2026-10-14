- The low-disk runbook now says that `--include-docker` also prunes Podman,
  including unused pods, and lists the Podman checks to run first. It also
  warns that `disk_cleanup.sh` exits `0` when a requested group is skipped
  with only a warning, so the output needs reading as well as the exit code.
