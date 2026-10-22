- `git_signing_doctor.py --verify-recent N` audits the signatures on the
  last `N` commits, the question behind "why do my commits show
  Unverified?". It reads git's own verdict for each commit, prints the
  counts, and names every bad, revoked, expired or unverifiable signature,
  every unsigned commit when `commit.gpgsign` is on, and every good signature
  whose signer address differs from the committer address. It judges your
  own commits unless `--all-authors` is given.
