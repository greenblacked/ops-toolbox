- `routeros_version.py record-hash` retried a host the instant a transfer
  failed, which was meant to match the Dockerfile's `wget --tries=3` but did
  not: wget waits between tries, and a retry fired at once usually meets the
  CDN edge that just cut the transfer in the same state. It now pauses two
  seconds before the second attempt and four before the third. A 404, or any
  4xx other than 408 or 429, moves to the next mirror at once instead of
  spending the remaining attempts on a file that is not there.
