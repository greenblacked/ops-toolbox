- `linux/stay_fresh.sh` emptied the Trash by removing the `files/` and `info/`
  directories rather than their contents, which the FreeDesktop spec expects
  to exist. On a Trash relocated to another disk — `files/` a symlink, the
  usual way to keep it off a small SSD — it deleted the symlink instead: the
  trashed files stayed where they were, nothing was freed, the relocation was
  destroyed, and the run reported success.
