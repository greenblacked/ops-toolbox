- `.claude/hooks/session-start.sh` did its network work — apt, two curls, an
  npx fetch — before the two steps that need no network, so the hook's
  timeout killed it mid-fetch and the macOS suite layout and the attribution
  guard were never installed. Those run first now, `.claude/settings.json`
  sets an explicit timeout, and `DEBIAN_FRONTEND=noninteractive` is passed
  through `env` so `sudo`'s `env_reset` cannot drop it. A `/repo` pointing at
  another checkout is no longer reported as a layout that is in place.
