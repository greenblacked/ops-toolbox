- `mikrotik/features/conntrack_watch.lua` warns before the connection-tracking
  table fills, the classic way a router stays up while new connections are
  dropped, and says when it has recovered. It reads the two counts the router
  already keeps, alerts only when the state changes, retries a send that
  failed, and changes nothing on the router. It skips with a log line when the
  maximum cannot be read, and it runs on RouterOS 7.24 from the start.
  `print_schedulers.sh` schedules it every five minutes.
