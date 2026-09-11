- `stay_fresh_agent.sh` escapes `--profile`, `--notify` and `--notify-when`
  before they reach the LaunchAgent plist, as it already did for the script
  and log paths two lines below. No value can reach that plist unescaped
  today — each is rejected by an exact-match validator first, which a security
  review confirmed by injection — so this makes the writer correct on its own
  rather than only because a validator elsewhere happens to be strict.
- The session hook extracts the ShellCheck and ruff release tarballs with
  `--no-same-owner`, so uid and gid records inside an archive are ignored.
