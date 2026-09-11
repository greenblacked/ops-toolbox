- `linux/disk_cleanup.sh --include-trash` half-emptied the Trash, and missed a
  relocated one entirely. It walked `find -type f`, so a trashed directory lost
  its files and stayed behind as an empty skeleton while its `.trashinfo`
  record was deleted with them, leaving an item that could no longer be
  restored or even identified. And where `files/` is a symlink — the usual way
  to keep a trash off a small SSD — `[[ -d ]]` followed the link but find did
  not, so the run announced "nothing in trash files" and freed nothing at all
  on the machine most likely to need the space. Both directories are now
  emptied with the same `find "$dir/" -mindepth 1 -delete` that
  `linux/stay_fresh.sh` already uses, which descends into a relocated trash,
  removes trashed directories whole and leaves the two directories the
  FreeDesktop spec expects to exist. The byte total is measured in a pass ahead
  of the delete rather than counted one unlink at a time, so a dry run still
  reports what it would free and still writes nothing. The cache directories
  keep the old walk, which leaves their tree in place on purpose.
