# Brute force blocker - scans /log for repeated authentication failures
# (SSH, Winbox, API) and adds offending source IPs to address-list brute-force-block.
#
# Schedule via /system scheduler with interval=1m.
#
# Pair with a firewall rule to drop traffic from the blocklist:
#   /ip firewall filter add chain=input action=drop \
#       src-address-list=brute-force-block comment=brute-force-block disabled=yes
# Review and enable the rule manually after adding it.
#
# Globals:
#   BF_SEEN_LINES   count of log lines processed in the previous run; used to
#                   scan only the delta on each run so the script stays O(new lines).
#
# Keywords matched in /log entries (case-sensitive, RouterOS log format):
#   "login failure"   - SSH and Winbox authentication failures
#   "login failed"    - API and WebFig failures
#   "invalid user"    - SSH invalid username attempts

:local DeviceName    [/system identity get name];

:local MaxFailures   5;
:local BlockTimeout  "1d";
:local ListName      "brute-force-block";

# Keywords that indicate a failed login attempt in RouterOS log.
:local Keywords {"login failure";"login failed";"invalid user"};

:global BF_SEEN_LINES;
:if ([:typeof $BF_SEEN_LINES] != "num") do={ :set BF_SEEN_LINES 0; }

# Tally source IPs from log messages matching any keyword.
# RouterOS log entries contain the source IP as "from X.X.X.X" or "<X.X.X.X>".
:local tally ";";
:local newAlerts "";
:local newCount 0;

:local logIds [/log find];
:local totalLines [:len $logIds];

:local i $BF_SEEN_LINES;
:while ($i < $totalLines) do={
    :local lid ($logIds->$i);
    :local msg "";
    :do { :set msg [/log get $lid message]; } on-error={};

    :local matched false;
    :foreach kw in=$Keywords do={
        :if (!$matched) do={
            :if ([:find $msg $kw] != nil) do={ :set matched true; }
        }
    }

    :if ($matched) do={
        # Extract IP: look for "from X.X.X.X" first, then "<X.X.X.X>".
        :local ip "";
        :local fromIdx [:find $msg "from "];
        :if ($fromIdx != nil) do={
            :local rest [:pick $msg ($fromIdx + 5) [:len $msg]];
            :local spaceIdx [:find $rest " "];
            :if ($spaceIdx != nil) do={
                :set ip [:pick $rest 0 $spaceIdx];
            } else={
                :set ip $rest;
            }
        } else={
            :local ltIdx [:find $msg "<"];
            :if ($ltIdx != nil) do={
                :local rest [:pick $msg ($ltIdx + 1) [:len $msg]];
                :local gtIdx [:find $rest ">"];
                :if ($gtIdx != nil) do={
                    :set ip [:pick $rest 0 $gtIdx];
                }
            }
        }

        # Strip port suffix if present (X.X.X.X:port).
        :if ([:len $ip] > 0) do={
            :local colon [:find $ip ":"];
            :if ($colon != nil) do={ :set ip [:pick $ip 0 $colon]; }
        }

        # Only act on plausible IPv4 addresses (contains at least one dot).
        :if (([:len $ip] > 6) and ([:find $ip "."] != nil)) do={
            :local key (";" . $ip . ";");
            :local existing [:find $tally $key];
            :if ($existing = nil) do={
                :set tally ($tally . $ip . ":1;");
            } else={
                # Increment the counter stored as "IP:COUNT" in the tally string.
                :local startCount ($existing + [:len $key] - 1);
                :local endCount [:find $tally ";" ($startCount + 1)];
                :if ($endCount != nil) do={
                    :local countStr [:pick $tally ($startCount + 1) $endCount];
                    :local colon2 [:find $countStr ":"];
                    :if ($colon2 != nil) do={
                        :local n ([:tonum [:pick $countStr ($colon2 + 1) [:len $countStr]]] + 1);
                        :set tally ([:pick $tally 0 ($startCount + $colon2 + 2)] . $n . \
                                    [:pick $tally $endCount [:len $tally]]);
                    }
                }
            }
        }
    }

    :set i ($i + 1);
}

:set BF_SEEN_LINES $totalLines;

# Walk tally and block IPs that hit MaxFailures.
:local tallyCopy $tally;
:local semiIdx [:find $tallyCopy ";" 1];
:while ($semiIdx != nil) do={
    :local entry [:pick $tallyCopy 1 $semiIdx];
    :local colonIdx [:find $entry ":"];
    :if ($colonIdx != nil) do={
        :local ip [:pick $entry 0 $colonIdx];
        :local cnt [:tonum [:pick $entry ($colonIdx + 1) [:len $entry]]];
        :if ($cnt >= $MaxFailures) do={
            :local alreadyBlocked false;
            :do {
                :local existing [/ip firewall address-list find list=$ListName address=$ip];
                :if ([:len $existing] > 0) do={ :set alreadyBlocked true; }
            } on-error={};
            :if (!$alreadyBlocked) do={
                :do {
                    /ip firewall address-list add list=$ListName address=$ip \
                        timeout=$BlockTimeout comment=("brute-force " . $cnt . " failures");
                    :set newCount ($newCount + 1);
                    :set newAlerts ($newAlerts . "%0A  <code>" . $ip . "</code> (" . $cnt . " failures)");
                    :log warning ("brute_force_block: blocking " . $ip . " after " . $cnt . " failures");
                } on-error={
                    :log error ("brute_force_block: address-list add failed for " . $ip);
                }
            }
        }
    }
    :set tallyCopy [:pick $tallyCopy ($semiIdx) [:len $tallyCopy]];
    :set semiIdx [:find $tallyCopy ";" 1];
}

:if ($newCount > 0) do={
    :local MessageText ("\F0\9F\9A\AB <b>" . $DeviceName . ":</b> brute force blocked " . \
                        $newCount . " IP(s)" . $newAlerts);
    :do {
        :local Send [:parse [/system script get tg_send source]];
        $Send MessageText=$MessageText;
    } on-error={ :log error "brute_force_block: tg_send unavailable"; }
} else={
    :log info ("brute_force_block: scan complete, no new blocks (total log lines=" . $totalLines . ")");
}
