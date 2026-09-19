- The two RouterOS discoverers disagreed about what a test fixture is. The CHR
  suite drops any directory named `tests` at any depth; the convention suite
  dropped only `mikrotik/tests/`, so a `.lua` under `features/tests/` was held
  to the script conventions by one and never loaded onto the router by the
  other. Both use the same rule now.
