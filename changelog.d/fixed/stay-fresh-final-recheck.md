- `macos-initial-setup/stay_fresh.sh` validates and removes npx entries one at
  a time after sizing, preserving entries refreshed between removals. Its
  internal cleanup mode cannot be overridden by the environment, and a missing
  cache root fails final validation. Verbose system-log checkpoints omit the
  repeated candidate inventory while retaining confirmed removal records.
