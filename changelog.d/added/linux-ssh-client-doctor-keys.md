- `linux/ssh_client_doctor.sh` grades whether ssh should use what is in
  `~/.ssh`, not only whether it can: private keys with no passphrase, DSA
  and short RSA keys, keys older than `--max-key-age` days, unhashed or
  conflicting known_hosts entries (aliases in the host field are
  expanded), duplicate authorized_keys lines, a `Host *` block that turns
  off host key checking or forwards the agent everywhere, and an
  `SSH_AUTH_SOCK` that points at a dead agent. `--only` and
  `--list-groups` select groups. It stays read-only: the passphrase
  probe cannot prompt and key material is never printed. An unquoted
  end-of-line `# comment` is dropped before a config value is graded, so
  `StrictHostKeyChecking no # legacy` is still caught. A `Ciphers` line
  is read with its list modifier: `-` removes names, so only `+`, `^` or
  a plain list that names CBC or arcfour is flagged.
