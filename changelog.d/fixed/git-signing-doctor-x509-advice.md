- `git_signing_doctor.py` gives advice that fits `gpg.format` when the value
  is an SSH public key: under `x509` it suggests a certificate ID or
  fingerprint that gpgsm accepts instead of a GPG key id.
