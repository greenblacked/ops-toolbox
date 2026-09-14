- `security_check.lua` wrote its emoji as `\\F0\\9F…`, a doubled backslash,
  where every other script in the folder writes `\F0\9F…`. RouterOS reads
  `"\F0"` as the byte and `"\\F0"` as a backslash followed by the letters F and
  0, so every finding in the Telegram report carried literal `\F0\9F\9F\A0`
  text instead of the severity marker it was meant to show — 126 of them. A
  convention check now holds every script to the single-backslash form, skipping
  comments, where `reboot-and-flush.lua` documents a shell command whose own
  quoting needs the doubled spelling.
