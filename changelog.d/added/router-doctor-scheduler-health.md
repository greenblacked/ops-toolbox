- `mikrotik/features/router_doctor.py` checks whether the schedulers it
  finds actually run. A disabled entry used to count as scheduled. An
  enabled entry still at `run-count` 0 long after its interval, which is
  what a policy too narrow for the script looks like, went unreported.
  `TgBotToken` set by hand with nothing to set it again at boot passed as
  healthy until the next reboot cleared it. All three are now warnings. They
  are judged only on what the router returned, and the search for a startup
  script that sets the token runs on the router, so no script source is
  read over ssh.
