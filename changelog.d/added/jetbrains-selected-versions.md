- Add repeatable `--prune-jetbrains-version NAME` to the macOS app-cache step.
  It removes only explicitly selected older versions from the default JetBrains
  settings/plugin, cache/Local History and log roots. Previews show exact paths
  and sizes. Newest/unselected versions, unsafe inventories and active or
  uninspectable IDEs are preserved; ordinary and deep cleanup keep version data.
