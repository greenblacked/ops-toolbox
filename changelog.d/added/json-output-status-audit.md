- `macos-initial-setup/status.sh` and `macos-initial-setup/hardening_audit.sh`
  take `--json`. Stdout then carries one versioned JSON object with the same
  verdicts the report prints (sections for the status, findings with their
  group, check and fix plus a summary for the audit) and nothing else, so an
  MDM extension attribute, a fleet check or a CI gate can read it without
  scraping coloured text. The exit codes are unchanged, the human report is
  byte for byte the same without the flag, and no `jq` or `python` is
  needed.
