- CI runs the no-Docker suites on the macOS runner, and a `templates/` change
  runs everything. `macos-15` is the only runner where BSD userland meets the
  test harness, and it was running one file; `static`, `k8s` and `dotfiles`
  now run there too, with a gate wide enough that a `test-env/` change wakes
  it. A `templates/` change previously matched no suite at all, so the two
  suites written to keep the templates from drifting ran on every change
  except the one that mattered. `Test / windows native` also gained the
  `Require pwsh` guard the Ubuntu matrix entry already had, without which the
  job passes over a runner that skipped itself.
