- `macos-initial-setup/stay_fresh.sh` adds `--prune-system-logs` to the
  diagnostics step for selected rotated system, installer and Wi-Fi log
  archives older than 30 days. The standalone
  `macos-initial-setup/lib/system_logs.py` validates each file before removal;
  previews write nothing, and current logs, recent archives, unrelated files
  and subdirectories are preserved. Deletion requires sudo and remains
  separate from automatic cache cleanup.
