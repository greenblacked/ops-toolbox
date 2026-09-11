- `stay_fresh_agent.sh install --ignore-power` was accepted, validated and
  reported as installed, but never reached the plist, so the agent it wrote
  went on deferring on battery and downgrading to reports while somebody
  typed — for good, and silently. The flag now travels into the
  `ProgramArguments` of the installed job. `status`, `run-now`, `logs` and
  `uninstall` have no firing to un-guard and swallowed it just as quietly;
  they now refuse it with exit 3, as their messages already promised.
