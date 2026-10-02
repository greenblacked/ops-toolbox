- `linux/config_backup.sh` validates private mode-0600 staged archives before
  publishing unique names without replacing existing files or following archive
  symlinks. Concurrent publication and retention are serialized; failed runs
  preserve previous generations, and explicitly named partial backups retain
  separately without evicting complete copies.
