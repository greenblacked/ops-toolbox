- `security_check.lua` never sent its report. It called `tg_send`, the package's
  older helper, while the two other scripts that run on RouterOS 7.24 —
  `backup_update_check.lua` and `stay_fresh.lua` — both default to `tg_send_new`,
  the operator's own copy and the one a 7.24 router actually has. It now does the
  same, with `SecuritySendScript` to name a third.
