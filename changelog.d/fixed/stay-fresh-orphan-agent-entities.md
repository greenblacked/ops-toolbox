- `stay_fresh.sh` reported a live LaunchAgent as orphaned when its program path
  contained a character XML escapes. A plist stores `R&D Tools` as
  `R&amp;D Tools`, the path was compared to the filesystem in that spelling, no
  such file existed, and `--prune-orphan-agents` deleted a working agent. The
  five predefined entities are decoded before the path is judged, `&amp;` last
  so `&amp;lt;` does not decode twice.
