- `stay_fresh.sh` reaches four cache roots it used to walk past: Spotify's
  `PersistentCache`, which is routinely several gigabytes and sits outside
  `~/Library/Caches` where the user-cache step cannot see it; `bun`'s package
  cache, through `bun pm cache rm` where that exists and the directory
  otherwise; `~/.minikube/cache`, whose ISOs and preload tarballs are hundreds
  of megabytes per Kubernetes version and are re-downloaded on demand; and
  `~/.gradle/wrapper/dists`, a whole Gradle distribution per version any
  project's wrapper ever asked for. Spotify is covered by the running-app
  guard like every other application, minikube's `machines/`, `profiles/` and
  `certs/` are never touched, and the Gradle wrapper distributions join the
  other build caches behind `--prune-build-caches`.
