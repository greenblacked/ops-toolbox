- `mikrotik/features/export_config.py --diff --summary` prints how many lines
  were added and removed in each RouterOS menu instead of the unified diff, so
  "what kind of change happened" can go into a ticket, a chat or an alert
  without the rule bodies, comments and addresses the full diff carries. A
  menu whose rules only changed order is listed too. Exit codes and the
  promise to write nothing are the same as `--diff` alone.
