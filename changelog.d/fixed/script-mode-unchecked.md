- A script with a shebang that nobody could run passed every check.
  `check_conventions.sh` asked whether an executable file earns its bit and
  never the converse, so `status.sh` arrived tracked 644 — reviewed and merged
  as a script you had to say `bash` in front of, while every usage line in the
  repository is written `./x.sh`. The check now runs both ways, exempting
  files whose own header says "Sourced, not executed" rather than matching on
  a path. It found `mikrotik/tests/routeros_version.py` the same way:
  `mikrotik/tests/run.sh` tells you to run it as `$HERE/routeros_version.py`,
  which could not work.
