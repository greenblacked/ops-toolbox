- `stay_fresh_agent.sh status` told a healthy job it was dead after an
  upgrade. Only `run-scheduled` writes the `last-scheduled` stamp and only
  since the version that added it, so an agent installed earlier had none
  however faithfully launchd fired it, and its plist mtime tripped the
  staleness threshold. With no stamp the age is reported and the exit stays
  0; a stale stamp still fails as before.
