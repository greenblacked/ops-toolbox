- `stay_fresh.sh` no longer reports WARN because a cache refilled itself.
  `/Library/Caches` is rewritten by running daemons within the same second it
  is cleared, so the check for leftover entries fired on every healthy Mac and
  the run's verdict was permanently yellow — the state the script's own comment
  above `warn_step` exists to prevent, since a verdict that is always yellow is
  one nobody reads. Entries that are back with nothing denied, nothing errored
  and nothing protected are now a plain warning that says what happened; a
  failed removal and an entry owned by another user still warn the step.
- The message no longer offers "protected or recreated" for entries that were
  never protected.
- Applications found running are listed comma-separated. `"${running[*]}"`
  joins on a space, so `Visual Studio Code` and `Brave Browser` arrived as one
  unbroken run of words naming an application nobody could look for.
