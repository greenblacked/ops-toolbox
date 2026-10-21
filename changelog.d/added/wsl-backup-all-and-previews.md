- `windows/wsl/wsl_manage.ps1 backup -All` exports every registered distro
  under one timestamp, the "export everything" step before a reinstall or an
  upgrade that used to be a loop written by hand. Docker Desktop's own
  distros are skipped, a running distro whose measured use will not fit on
  the destination drive (counting the exports already admitted
  in the same run) is refused before anything is written (a stopped one
  is never started to measure it), one failed export does not stop the rest
  and never deletes a backup of the same name from an earlier run (exports
  are written to a temporary file and moved into place on success),
  and every tar gets the same `.sha256` sidecar a single backup writes.
  `-DryRun` now previews `backup`, `compact`, `sparse` and `shutdown` as well:
  the plan with sizes, the running distros a shutdown would stop, and, for
  `compact`, whether the shell is elevated, without calling `wsl --export`,
  `wsl --shutdown`, `wsl --manage` or diskpart.
- `backup -DestDir D:` (a bare drive) now means the drive root `D:\`, not the
  drive-relative current directory, for both a single distro and `-All`, which
  now build the output path the same way.
