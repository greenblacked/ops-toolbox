- `routeros_version.py record-hash` hashed whatever arrived, so the digest
  that pins the CHR image described a truncated download as confidently as a
  complete one. `http.client` returns an empty read and closes the connection
  when a `Content-Length` body is cut short rather than raising — the standard
  library documents the choice in a comment — so the chunk loop read a partial
  body to what looked like the end of the file. Two scheduled release checks
  recorded two different digests for the same `chr-7.24.4.vdi.zip` four days
  apart, and both were rejected by the image build's own `sha256sum -c`; that
  rejection is the only reason this was ever visible. The transfer is now
  measured against the length the server announced, a body with neither a
  length nor chunk framing is refused because its end cannot be told from a
  dropped connection, and a complete body that is HTML or far too small to be
  an archive is refused as well — an error page served under a 200 is whole by
  every framing test and would otherwise be pinned as though it were the
  image. Each host is retried the way the Dockerfile's `wget --tries=3`
  already does before the next mirror is tried, and the host and byte count
  are reported on stderr, leaving stdout to carry the digest alone.
