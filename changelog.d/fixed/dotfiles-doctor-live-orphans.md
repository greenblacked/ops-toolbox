- `dotfiles/dotfiles_doctor.sh` now runs the credential scan on a link
  that a renamed install target left behind while it still points at an
  existing file in the repository; only dangling ones were skipped
  before, with a warning.
