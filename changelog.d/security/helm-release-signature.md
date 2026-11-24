- `v1_stay_fresh.sh` now verifies the Helm tarball's detached GPG signature
  against Helm's release keys, pinned by full fingerprint in the script, before
  installing it. The `.sha256sum` is served from the same host as the tarball,
  so a compromised `get.helm.sh` could replace both; the signature chains to
  keys fetched from the `helm/helm` repository instead, and the signature itself
  comes from the GitHub release. The extracted binary must report the version
  being installed. The install is refused
  when `gpg` is missing or the signer is not pinned.
