- The macOS disk report measures again. It ran `du -a -k -x -d 1`, and BSD du
  spells its usage `[-a | -s | -d depth]` — the three are mutually exclusive and
  it exits 64, `EX_USAGE`, for any pair. So the step whose whole job is to say
  what is large had never produced a number on macOS: all ten roots printed
  "total unknown" and warned, ten warnings a run. GNU du accepts the pair, which
  is why the Linux container every suite runs in never saw it. The portable
  spelling is `-s` on the root and `-s` on each entry, which also keeps files —
  `~/Downloads` and `~/Movies` are where one large file is usually the answer.
- A root that du could only partially read reports the total it did read
  instead of discarding it. macOS keeps directories under `~/Library/Caches`
  and `~/Library/Containers` that the user cannot enter, so du prints a sum and
  exits 1 on every healthy machine; that was being treated as a failed
  measurement and warned about. It is a plain line saying "at least" now, and
  the largest entries under it are listed as they are for any other root.
- Paths in the report render as `~/Library/Caches`, not `\~/Library/Caches`. The
  replacement in `${path/#$HOME/...}` is held in a variable now, because neither
  literal survives both shells: bash 5 tilde-expands a bare `~` back into the
  real home path, and the bash 3.2 that `/bin/bash` is on macOS leaves `\~` as a
  literal backslash-tilde. The suite runs on bash 5 and saw the tilde it
  expected while every Mac printed the backslash.
- `test-env/static/check_conventions.sh` fails any script that combines two of
  du's `-a`, `-s` and `-d`, so the next one is caught where the suites run
  rather than only on a Mac.
