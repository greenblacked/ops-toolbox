- `security_check.lua` said only `tg_send unavailable` when its report did not
  go out, with one `:do` block around both the parse and the call — the same
  sentence whether the helper is missing, refuses to parse, or raises while
  sending. A security audit that goes quiet for an unknown reason is the exact
  failure this script exists to prevent, because a missing report looks like a
  clean result. The two halves are now separate, the send resolves the helper's
  name through a variable and parses it once (the shape `backup_update_check.lua`
  proves end to end on a 7.24 CHR), and `SecSendError` records which half failed
  so a scheduler or a test can alert on it.
