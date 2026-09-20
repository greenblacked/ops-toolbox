- `export_config.py` defaulted `--out` to a directory beside itself, so moving
  the file into `mikrotik/features/` moved the export history with it. An
  operator with stored exports would have written to an empty
  `mikrotik/features/config-history/` on the next run and diffed `--diff`
  against nothing, with no message and every previous export still in
  `mikrotik/config-history/`. The default is keyed off the package root, where
  the README says it is.
