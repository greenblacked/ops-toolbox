- `windows/setup/path_doctor.ps1` reports what is wrong with the Windows
  PATH, read raw from the registry: duplicate, dead, relative and quoted
  entries (a quoted or `%VARIABLE%` entry never makes a later plain copy of
  the same folder a duplicate, in the report as in `clean`), a `REG_SZ` value whose `%VARIABLES%` never expand, a value long
  enough for `setx` to truncate, and the Microsoft Store `python.exe` alias
  or Git's MSYS `find.exe` answering ahead of the real one. `clean` removes
  only empty, repeated and missing entries from the user PATH (an entry it
  cannot judge, such as a quoted one, never makes a later usable copy of the
  same folder a duplicate): it refuses
  without `-Yes`, previews with `-DryRun`, writes a backup first, keeps the
  value's registry kind and reads it back to verify.
