- `stay_fresh.sh` now documents the warnings a clean machine still
  produces. SIP leaves Apple-owned directories under `/Library/Caches` that
  the system-cache step cannot delete, and `kubectl krew upgrade` exits
  non-zero when a plugin is already newest; both used to look like leftover
  work in the log. The user-cache refusals, a Trash without Full Disk Access,
  and a root-owned gcloud log directory are called out so the first two are
  not mistaken for the third.
