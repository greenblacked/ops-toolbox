- The RouterOS integration suite decides which scripts it expects to run from
  the scripts themselves, not from a hand-kept list of two names. A
  `:global` or `:local` whose name contains an underscore is what RouterOS 7.24
  refuses to execute, so that is what the marker now reads. The list had gone
  stale: `health_check` declares no underscored name and was still marked
  `xfail`, so every run reported `XPASS` — a test asserting the opposite of the
  truth, tolerated only because the marker is not strict. Each remaining Wave C
  rename now flips its own case with no edit to the suite.
