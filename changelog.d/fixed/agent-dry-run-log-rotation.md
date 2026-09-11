- `stay_fresh_agent.sh run-scheduled --dry-run` deleted real logs. The
  rotation that keeps the ten newest transcripts sat below the
  `AGENT_DRY_RUN` guard on the run stamp with nothing guarding it, so
  previewing a schedule change destroyed the oldest records of what the
  schedule had actually been doing. A dry run now rotates nothing; it still
  writes its own transcript, which is the step list being previewed. The
  scratch file the rotation reads through is also checked before use: an
  unchecked `mktemp` on a full disk — the condition the agent exists to
  postpone — left the path empty, so the redirect and the loop each
  addressed a file with no name and the rotation quietly stopped happening.
