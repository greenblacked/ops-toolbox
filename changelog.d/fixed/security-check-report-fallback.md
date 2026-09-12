- `security_check.lua` lost its whole report when the Telegram send failed. On a
  router with seventeen findings the message is built from seventeen quoted
  commands, and a send that is rejected — for length or anything else — took the
  counts with it, so the run with the most to say was the one that said nothing.
  A failed send now falls back to the counts alone, short by construction, which
  still tells somebody to go and look; `SecSendError` records whether the
  fallback went out or failed too.
