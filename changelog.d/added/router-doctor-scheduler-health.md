- `mikrotik/features/router_doctor.py` checks whether the schedulers it
  finds actually run. A disabled entry used to count as scheduled. An
  enabled entry still at `run-count` 0 long after its first run was due,
  which is what a policy too narrow for the script looks like, went
  unreported. That is judged from its `start-date`, `start-time` and
  interval against the router's clock, not from the router's uptime, so a
  scheduler created minutes ago is not accused. A start that does not show
  when the entry was added (`start-date` 1970, which RouterOS fills in when
  only `start-time` is given, or a start before the last boot) is reported
  as not judged.
  `TgBotToken` set by hand with nothing to set it again at boot passed as
  healthy until the next reboot cleared it. All three are now warnings. They
  are judged only on what the router returned, and the search for a startup
  script that assigns the token (`:global NAME value`, or `:global NAME`
  before `:set NAME value`; not a mere mention or read, and a scheduler must
  run the script, not only share its name; `:execute NAME` and a bare
  name among other statements do not count) finds its candidates on the
  router and judges them locally, so no script source is read over ssh.
