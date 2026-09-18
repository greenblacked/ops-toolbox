- Disable Python bytecode writes during LaunchAgent plist inspection and Conda
  metadata parsing, keeping maintenance previews free of interpreter cache files
  on macOS. Ignore ambient Python import settings for these internal parsers.
