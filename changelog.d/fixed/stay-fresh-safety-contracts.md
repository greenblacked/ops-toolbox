- `macos-initial-setup/stay_fresh.sh` preserves unpublished run locks and checks
  ownership before releasing them, preventing concurrent maintenance during
  startup and stale-lock recovery. LaunchAgent inspection parses complete XML
  and binary plists and respects `Program` before `ProgramArguments`.
- Plugin discovery failures and timeouts count as warnings instead of empty
  inventories. Previews avoid plugin queries that can initialize state.
- `macos-initial-setup/launchd/stay_fresh_agent.sh` prints scheduled previews
  to stdout without creating transcripts, log directories or scheduled-run
  stamps, and leaves existing logs unchanged.
