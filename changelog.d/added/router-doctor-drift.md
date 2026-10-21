- `mikrotik/features/router_doctor.py --drift` says which installed scripts
  differ from the files in this checkout, so a router still running an old or
  hand-edited copy is visible without opening each script in Winbox. The file
  is passed into the router as an argument of a `:parse`d function and the
  router compares it with each script's source, answering only same, changed
  or missing, so no script source, and no token pasted into one, crosses the
  wire and nothing is written to the router. A difference is a warning naming
  the file to paste; the JSON output carries only the verdict per script. A
  CHR test runs the comparison, with quotes, dollars, backslashes and
  newlines in the source, on the pinned RouterOS release.
