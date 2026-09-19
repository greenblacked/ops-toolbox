- `backup_update_check.lua` marks the one outcome that wants an operator:
  "update is required" now carries the word `ALARM` on its own line under the
  headline. The daily heartbeat and the failed-check notice do not, and the CHR
  suite asserts both halves — the alarm present with the newline that puts it on
  its own line, and absent from every other outcome. A router offering an
  upgrade and a router with nothing to do used to open with the same sentence,
  differing only in the word "not", which is the difference a phone notification
  is worst at showing.
