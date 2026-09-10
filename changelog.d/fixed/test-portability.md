- `test-env/static/test_changelog.sh` used GNU-only `find -printf` with no
  fallback, so on macOS its three "writes nothing" assertions compared two
  empty strings and passed vacuously, and two bare `sed -i` calls failed
  outright there. The one real invocation in `linux/tests/`'s new block was
  not bracketed with `set +e`, which made its assertion unfailable and would
  have taken the forty assertions after it down with the suite.
