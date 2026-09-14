- `security_check.lua` lost its posture fingerprint whenever the Telegram
  helper raised. The call to the helper sat outside `:do{}on-error={}`, so a
  raise mid-send propagated and killed the script before `:set SecLastFp` —
  and a scan that forgets its own fingerprint reports `initial scan` on the
  next run instead of the posture change it exists to report. One Telegram
  outage was enough to make the audit blind to a change that happened during
  it. The call is now wrapped, as all three send sites in
  `backup_update_check.lua` already were. The comment that justified leaving
  it unwrapped claimed `backup_update_check.lua` calls its own helper from a
  plain `:if`; it does not, and the send that appeared to need the unwrapped
  form was failing for two unrelated reasons since fixed — the test installed
  no `tg_send_new` stub, and it drove the script through
  `/system/script/run`, which this CHR refuses for any source declaring an
  underscored `:global`. `SecSendError` now distinguishes a helper that
  raised from one that never returned, and the CHR suite covers the raising
  case. `SecSendError` and the new `PuTgStubReached` join the globals the
  session cleans between runs.
