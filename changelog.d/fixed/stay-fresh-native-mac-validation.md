- Native macOS testing of `macos-initial-setup/stay_fresh.sh` identified
  valid lsof file-descriptor fields that the log guards rejected. Both parsers
  now accept validated descriptor fields while retaining the directory witness
  requirement. Native CI covers real lsof and process-list output. Deep
  messenger previews use one installed-app inventory to avoid counting standard
  profile caches twice.
