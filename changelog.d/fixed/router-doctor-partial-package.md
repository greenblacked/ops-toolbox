- `router_doctor.py` could report the deployed scripts as strangers. It walks
  the package to learn which scripts should be on the router, and `os.walk`
  swallows a per-directory read error and keeps going, so an unreadable
  `core/` produced a list that looked complete and was short — every name it
  lost then showed up as a script the router has and the package does not, in
  a tool whose whole job is to say what is missing. A directory that cannot be
  read is now an error (exit 2, in both text and `--format json`); a directory
  that is simply not there still returns nothing, because the script has to
  survive being copied on its own into `~/bin`.
