- `mikrotik/features/print_startup.sh` prints the startup script that
  declares the RouterOS globals again at every boot, and its
  `start-time=startup` scheduler entry. Globals are cleared by a reboot, and
  that script used to be written by hand from notes spread across the README,
  which is how a token set by hand quietly stopped working after the next
  restart. The output has placeholders for the secrets, so it is safe to keep;
  `--only` adds a script's settings at their defaults, and `--from-env` fills
  the secrets from environment variables rather than the command line. No
  name it prints has an underscore, so it runs on RouterOS 7.24.
