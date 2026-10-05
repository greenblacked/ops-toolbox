- `stay_fresh.sh` no longer warns Clear system caches because `find` cannot
  state a SIP- or TCC-protected entry under `/Library/Caches`. Those entries
  were already kept; the verification `find` exits non-zero for the same
  refusal, and that exit was counted as a failed clear, so a healthy Mac
  finished WARN on every run. An error that is not `Operation not permitted`
  still warns the step.
- A launchd plist that Python's XML parser rejects no longer dumps a
  traceback. When `plutil` can read it, the program is inspected; otherwise
  the plist stays uninspected and is not removed.
