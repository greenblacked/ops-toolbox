- `linux/tls_expiry.sh` checks the other half of a certificate outage, a
  certificate that is valid but wrong. `--check-host` fails when the
  certificate does not cover a name, and `--deep` adds the name check for
  each host, the chain as the handshake verified it (a provably missing
  intermediate fails, an issuer that is merely not trusted locally or a
  self-signed one warns, and `--cafile` supplies a private root and replaces
  system trust, passing `-no-CApath` and `-no-CAstore` to the handshake and
  the verify probe where openssl supports them and saying so when it
  cannot), the key size against `--min-key-bits` and MD5 or SHA-1
  signatures. `--hosts-file` reads a list of endpoints. The chain comes
  from the handshake the expiry check already makes, and default runs
  behave as before. An IPv6 target is written in brackets, with or without
  a port; an unbracketed one is refused.
