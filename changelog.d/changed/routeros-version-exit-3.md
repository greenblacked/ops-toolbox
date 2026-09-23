- `routeros_version.py` exits `3` on an unrecognised flag, for every
  subcommand, like the other Python CLIs. It had kept `argparse`'s `2`, which
  this repository spends on a wrong environment; it sits under `tests/`, so the
  unknown-flag contract in the static suite never reached it.
