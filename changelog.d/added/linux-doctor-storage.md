- `linux/system_doctor.sh` has a storage section for the failures `df` does
  not show: a real filesystem mounted read-only although fstab says
  read-write (not a mount fstab declares ro, a `:ro` bind with no fstab
  entry, `errors=remount-ro` alone, or the ostree `/sysroot`), an fstab entry
  that is not mounted (a note when it is `nofail`), a degraded md array, a
  disk whose SMART health is FAILED (as root), and an NFS, CIFS or sshfs
  mount that does not answer a five-second `stat`. `--skip-remote-mounts`
  and `--skip-smart` leave those probes out. It stays read-only and still
  never exits 1.
