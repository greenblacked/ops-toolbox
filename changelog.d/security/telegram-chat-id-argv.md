- Telegram notifications put the chat id on the `curl` command line
  (`--data-urlencode chat_id=...`). The bot token already rode in a stdin
  config so `ps` could not read it; the chat id did not. It goes in the same
  config now.
