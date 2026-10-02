- `macos-initial-setup/stay_fresh.sh` extends deep cleanup with installed
  messenger profile and partition caches, including sandboxed Slack. Exact
  renderer-cache leaves are selected; conversation stores, attachments, login
  state and whole containers remain intact. Active or unknown messenger
  activity preserves these caches even when the force option is supplied.
