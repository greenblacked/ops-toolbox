- `backup.lua` runs on RouterOS 7.24. Its two globals are now `RouterBackupPassword` — the name
  `backup_update_check.lua` and `stay_fresh.lua` already read for the same
  secret — and `BackupRemovePrevious`; 7.24 refuses to execute any script declaring a
  `:global` with an underscore in its name, and it stops in the parser, so the
  scheduled job logged nothing and looked exactly like a run with nothing to
  report. Fifteen of the 28 `.lua` scripts are still in that state, down from
  sixteen.
- `update_check.lua` is retired on 7.24 rather than renamed: it declares six
  underscored globals and `backup_update_check.lua` already does the same job
  there. It stays unchanged and supported for 7.23 and earlier.
- **If you run both on 7.23, set both spellings.** The two scripts shared
  `BACKUP_PASSWORD` and `BACKUP_REMOVE_PREVIOUS` because how many generations
  live on a router is one policy and not two. `backup.lua` reads the CamelCase
  pair now and `update_check.lua` still reads the underscored one, so a 7.23
  router running both needs both set or they will disagree about retention and
  encryption. On 7.24 only `backup.lua` runs and only the new pair matters.
- `backup.lua`'s notification says `Encryption: none` when no password is set.
  A router whose startup script still sets the old `BACKUP_PASSWORD` reads an
  empty password after this change and writes plaintext; that cannot be
  recovered from inside the script, because the old declaration is what 7.24
  refuses to run, so the nightly message names it instead of passing for an
  encrypted backup.
