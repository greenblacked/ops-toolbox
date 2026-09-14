- `security_check.lua` never sent its report. It called `tg_send`, the package's
  older helper, while the two other scripts that run on RouterOS 7.24 —
  `backup_update_check.lua` and `stay_fresh.lua` — both default to `tg_send_new`,
  the operator's own copy and the one a 7.24 router actually has. It now does the
  same, with `SecuritySendScript` to name a third.
- The call also sat inside a `:do {} on-error={}` block, where it raised for every
  message, a one-line one included — which is what ruled out the report's length
  and content. `backup_update_check.lua` parses its helper inside such a block but
  calls it from a plain `:if`, and that is the shape used here now. Losing the
  block costs the guard around the send, so `SecSendError` is set before the call
  and cleared after it: a run that dies in the helper leaves behind the sentence
  saying so, and the type of the value it tried to call.
