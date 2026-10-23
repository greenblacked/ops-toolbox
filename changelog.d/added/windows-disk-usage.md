- `windows/cleanup/disk_usage.ps1` reports what is filling `C:` before
  anything is deleted: the hibernation and page files, `Windows.old`, the
  component store, Docker data, every WSL distro's disk and the usual
  developer caches, each with the tool that gives the space back. Rows that
  `clean_disk_c.ps1` can reach end in the exact preview and cleanup command
  lines; a WSL disk points at `wsl_manage.ps1`. `tree` shows the largest
  folders under any path. It is read-only, never follows a junction or
  symbolic link (a OneDrive placeholder or Files On-Demand folder is not
  one, and counts), counts a sparse, compressed or placeholder file at
  the space it occupies rather than its logical size, and says when a
  size is a lower bound because a folder could not be read. Sizes are
  apparent: a file with several hard links counts once per link, and the
  report says so.
