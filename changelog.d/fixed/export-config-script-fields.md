- `mikrotik/features/export_config.py`: the secret scan covers more script
  fields and more ways of writing a secret. Any field named `*-script` or
  `on-*` (netwatch `up-script`, `down-script` and `test-script`, dhcp-server
  `lease-script`, vrrp `on-master`, `on-backup` and `on-fault`) is read as
  script text, not only `source` and `on-event`. A `password=`, `secret=`,
  `psk=` or other show-sensitive field written inside a script with escaped
  quotes (`password=\"...\"`, as in `/ppp secret add`, `/tool fetch` and
  `/tool e-mail send`) is found and redacted; an escaped variable
  (`\$pw`) is not a value. The name list gains `pass`, `pwd` and `cred`
  as words (`bypass` and `compass` stay clean), `credential`, `bearer` and
  `hmac`, and `key` and `auth` as words that count only given a plain
  literal.
