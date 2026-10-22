- `dotfiles/dotfiles_doctor.sh` skips the `ssh -G` probe when an `Include`
  line has a backslash before anything but a space, quote or backslash, as
  OpenSSH keeps such escapes and the doctor cannot tell what it would
  follow.
