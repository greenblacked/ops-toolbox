- The aggregator's contract tests never ran a failing suite. Every fake
  runner `test-env/static/test_run_tests.sh` built exited 0, so the one
  property each CI verdict rests on — a failing suite makes `run-tests.sh`
  exit non-zero and record `"status":"fail"` in the JSON summary — was
  asserted nowhere, and a regression in `run_suite` or in the summary
  writer would have kept every `Test / <suite>` job green while the suites
  underneath it failed. The fakes now record that they ran and what they
  were handed, so a skipped suite can no longer be mistaken for a failing
  one, and the checks cover a failing suite, a run mixing a failing suite
  with a passing one named after it, the `--` passthrough the CHR
  workflows depend on, the `--summary-file=VALUE` spelling, and that
  `run-tests.sh all git` runs the git suite once rather than twice.
