- `v1_stay_fresh.sh` no longer pipes Helm's `get-helm-3` installer from the
  upstream `main` branch into `bash`. It downloads the release tarball for the
  target version from `get.helm.sh`, checks it against the published
  `.sha256sum`, and only then installs the binary.
