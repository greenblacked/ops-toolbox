- `windows/setup/tls_expiry.ps1` checks certificate expiry on Windows with
  the exit codes of `linux/tls_expiry.sh`: PEM, CRT, CER or DER files, the
  leaf a TLS endpoint presents, and the Personal certificate stores of the
  user and the machine, where client-authentication, code-signing, RDP and
  WinRM certificates live. Trust-anchor stores are never scanned. Endpoints
  are read with a validation callback scoped to that one connection, so an
  expired or mismatched certificate is still reported, and no private key
  is ever read.
