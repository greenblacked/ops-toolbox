- `dotfiles/dotfiles_doctor.sh` no longer runs `ssh -G` on a config that
  uses `Match exec`, directly or through an `Include`: it warns and skips,
  so the read-only promise holds. The probe also runs once instead of twice.
