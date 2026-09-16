- `stay_fresh.sh` emptied nothing when the Trash had been relocated. A Trash
  moved off a small internal SSD is a symlink: `[[ -d ]]` follows it, but
  `find -P` does not descend into a symlinked start point and `du` does not
  measure through one, so the step walked nothing, deleted nothing, and printed
  "freed 0B" as though the Trash had been empty — on the machine most likely to
  need the space. `~/.Trash`, the verification pass and each mounted volume's
  `.Trashes/<uid>`, including the probe that decides whether a volume is worth
  opening, now carry the trailing slash `linux/stay_fresh.sh` already used.
  The comments in `linux/stay_fresh.sh` and `linux/disk_cleanup.sh` that named
  the macOS script as the reference for that form were describing something it
  did not do; they now say which file they mean and what it does.
