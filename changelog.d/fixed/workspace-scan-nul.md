- `lib/workspace_scan.py` aborted the whole scan with a traceback on a
  workspace path containing a NUL byte: `os.lstat()` raises `ValueError`,
  which is not an `OSError`, and nothing caught it. One unparsable manifest
  left every entry for every editor unclassified. Such a path is now
  `unresolved`, like any other it cannot reach.
