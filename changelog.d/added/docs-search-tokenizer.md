- The documentation site's search finds scripts, paths and flags by any part
  of their name. Terms used to split only at spaces and hyphens, so
  `disk_cleanup.sh` was one word that "cleanup" never found; they now also
  split at underscores, slashes, dots, brackets and camelCase, so "dry run"
  finds the pages about dry runs and "bot token" finds `TgBotToken`. Version
  numbers such as 7.24.6 stay whole. A `?q=` link opens the search with its
  term already typed.
