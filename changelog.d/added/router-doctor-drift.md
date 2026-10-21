- `mikrotik/features/router_doctor.py --drift` says which installed scripts
  differ from the files in this checkout, so a router still running an old or
  hand-edited copy is visible without opening each script in Winbox. The
  router computes the length and SHA-256 of each script and returns only
  those, so no script source, and no token pasted into one, crosses the wire.
  A difference is a warning naming the file to paste; the JSON output carries
  only the verdict per script. A CHR test checks the digest expression on the
  pinned RouterOS release.
