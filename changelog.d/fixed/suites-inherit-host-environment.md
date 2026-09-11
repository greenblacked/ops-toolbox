- The test suites no longer inherit the variables the scripts they run read
  from the environment — `XDG_CACHE_HOME`, `BUN_INSTALL`,
  `TF_PLUGIN_CACHE_DIR`, `UV_CACHE_DIR`, `STAY_FRESH_LOCK_DIR` and the
  notifier tokens among them. Inherited, they aim a run at a real cache or a
  real webhook instead of the fixture: one exported `BUN_INSTALL` satisfied a
  relocation assertion from `~/.bun`, passing locally and failing in CI. A
  static check now derives the set from the scripts themselves, so the next
  such variable is covered by the commit that reads it.
- Two `BUN_INSTALL` assignments in the macOS steps suite were written as
  `VAR=x out="$(...)"`, which is two shell assignments rather than a command
  prefix: the value outlived its test and pointed every later run at a
  deleted fixture.
