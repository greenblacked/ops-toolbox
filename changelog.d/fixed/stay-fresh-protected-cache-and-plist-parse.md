- `stay_fresh.sh` no longer warns Clear system caches because `find` cannot
  state a SIP- or TCC-protected entry under `/Library/Caches`. Those entries
  were already kept; the verification `find` exits non-zero for the same
  refusal, and that exit was counted as a failed clear, so a healthy Mac
  finished WARN on every run. Only a child is ignored that way. `Operation not
  permitted` on `/Library/Caches` itself means the contents were never listed,
  and that still warns the step, as does any other verification error.
- A launchd plist that Python's XML parser rejects no longer dumps a
  traceback. When `plutil` can read it, the program is inspected; otherwise
  the plist stays uninspected and is not removed.
