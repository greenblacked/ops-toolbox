# Flushes DNS cache + connection tracking and reboots the router.
#
# Intentionally does NOT send a Telegram notification before rebooting:
# /tool fetch can take seconds to complete and conntrack/DNS state is being
# torn down here, so a "rebooting now" message is racy and often arrives
# after the router is already offline.
#
# If you want a notification, add a tiny scheduler entry that runs on
# startup, e.g.:
#     /system scheduler add name=notify-boot start-time=startup \
#         on-event=":delay 20s; \
#                   :local Send [:parse [/system script get tg_send source]]; \
#                   \$Send MessageText=(\"\\F0\\9F\\9F\\A2 <b>\" . [/system identity get name] . \":</b> back online\");" \
#         policy=read,write,policy,test,sensitive,ftp

:log info "reboot-and-flush: flushing DNS cache";
/ip dns cache flush;

:do {
    :log info "reboot-and-flush: flushing connection tracking";
    /ip firewall connection remove [find];
} on-error={};

:log info "reboot-and-flush: rebooting now";
:delay 1s;
/system reboot;
