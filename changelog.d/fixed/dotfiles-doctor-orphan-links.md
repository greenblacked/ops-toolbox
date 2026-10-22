- `dotfiles/dotfiles_doctor.sh` now warns about dangling links into the
  repository for configs that were renamed or deleted, which the loop over
  the current sources never reached.
