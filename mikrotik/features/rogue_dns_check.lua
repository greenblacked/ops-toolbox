# Rogue DNS detector. Two checks per run:
#   1. Upstream sanity: resolve a control hostname (default "one.one.one.one")
#      and verify it resolves to an IP listed in :global DnsExpected. A
#      mismatch suggests upstream hijack, DoH/DoT leak, or a wrong resolver.
#   2. Client behavior: scan /ip firewall connection for outbound dst-port=53
#      flows whose destination is neither the router itself nor a resolver in
#      :global DnsAllowedResolvers. Aggregates the offenders by source IP.
#
# Schedule via /system scheduler with interval=10m.
#
# Globals:
#   DnsExpected            ";1.1.1.1;1.0.0.1;..." - any IP that the control
#                           hostname is allowed to resolve to.
#   DnsAllowedResolvers   ";1.1.1.1;8.8.8.8;..." - resolvers clients are
#                           allowed to talk to. The router's own IPs are added
#                           automatically.
#   RdnsDeliveredSig        signature Telegram acknowledged; suppresses repeats.
#   RdnsSendError           last delivery failure.
#   RdnsSendScript          helper name (default tg_send).
# Names omit underscores for RouterOS 7.24 execution compatibility.
#
# Action mode:
#   When Enforce is true, offending source IPs are tagged into address-list
#   rogue-dns-clients with a timeout. Use a documented filter rule (see README)
#   to drop or redirect their port-53 traffic.

# Fleet-wide maintenance switch; router_doctor.py reports when it is active.
:global OpsToolboxPaused;
:if (([:typeof $OpsToolboxPaused] = "bool") and $OpsToolboxPaused) do={ :return ""; }

:local DeviceName [/system identity get name];

:local Enforce      true;
# one.one.one.one is Cloudflare's anycast name for 1.1.1.1 / 1.0.0.1.
# dns.cloudflare.com resolves elsewhere and false-alarms on a healthy resolver.
:local CtrlHost     "one.one.one.one";
:local ListName     "rogue-dns-clients";
:local ListTimeout  "1h";
:local TopN         5;

:global DnsExpected;
:global DnsAllowedResolvers;
:global RdnsDeliveredSig;
:global RdnsSendError;
:global RdnsSendScript;

:if ([:typeof $DnsExpected] != "str") do={ :set DnsExpected ";1.1.1.1;1.0.0.1;"; }
:if ([:typeof $DnsAllowedResolvers] != "str") do={
    :set DnsAllowedResolvers ";1.1.1.1;1.0.0.1;8.8.8.8;8.8.4.4;";
}
:if ([:typeof $RdnsDeliveredSig] != "str") do={ :set RdnsDeliveredSig ""; }

:local expected $DnsExpected;
:if ([:pick $expected 0 1] != ";") do={ :set expected (";" . $expected); }
:if ([:pick $expected ([:len $expected] - 1) [:len $expected]] != ";") do={ :set expected ($expected . ";"); }

:local allowed $DnsAllowedResolvers;
:if ([:pick $allowed 0 1] != ";") do={ :set allowed (";" . $allowed); }
:if ([:pick $allowed ([:len $allowed] - 1) [:len $allowed]] != ";") do={ :set allowed ($allowed . ";"); }

# Build a router-self-IP allowlist so clients hitting the router's own IPs for
# DNS are not flagged.
:local routerIps ";";
:do {
    :foreach aid in=[/ip address find] do={
        :local a [/ip address get $aid address];
        :local slash [:find $a "/"];
        :if ($slash != nil) do={ :set a [:pick $a 0 $slash]; }
        :set routerIps ($routerIps . $a . ";");
    }
} on-error={};

# Check 1: upstream sanity.
:local upstreamAlert "";
:do {
    :local resolved [:resolve $CtrlHost];
    :local resolvedStr ($resolved . "");
    :if ([:len $resolvedStr] > 0) do={
        :if ([:find $expected (";" . $resolvedStr . ";")] = nil) do={
            :set upstreamAlert ("\nUpstream sanity: " . $CtrlHost . \
                                " -> " . $resolvedStr . " (not in DnsExpected)");
        }
    }
} on-error={
    :set upstreamAlert ("\nUpstream sanity: resolve(" . $CtrlHost . ") failed");
}

# Check 2: client behavior. Iterate all connections, filter to UDP/TCP dst-port 53,
# skip allowed resolvers and router-self destinations, aggregate unique src->dst pairs.
:local offenderInfo "";
:local offenderCount 0;
:local offenderSig ";";
:local seenPairs ";";

:do {
    :foreach cid in=[/ip firewall connection find] do={
        :local proto "";
        :do { :set proto [/ip firewall connection get $cid protocol]; } on-error={};
        :if (($proto = "udp") or ($proto = "tcp")) do={
            :local dst [/ip firewall connection get $cid dst-address];
            :local colon [:find $dst ":"];
            :local dstPort "";
            :local dstIp $dst;
            :if ($colon != nil) do={
                :set dstIp [:pick $dst 0 $colon];
                :set dstPort [:pick $dst ($colon + 1) [:len $dst]];
            }
            :if ($dstPort = "53") do={
                :if ([:find $allowed (";" . $dstIp . ";")] = nil) do={
                    :if ([:find $routerIps (";" . $dstIp . ";")] = nil) do={
                        :local src [/ip firewall connection get $cid src-address];
                        :local sColon [:find $src ":"];
                        :local srcIp $src;
                        :if ($sColon != nil) do={ :set srcIp [:pick $src 0 $sColon]; }
                        :local key (";" . $srcIp . "->" . $dstIp . ";");
                        :if ([:find $seenPairs $key] = nil) do={
                            :set seenPairs ($seenPairs . $srcIp . "->" . $dstIp . ";");
                            :set offenderCount ($offenderCount + 1);
                            :set offenderSig ($offenderSig . $srcIp . "->" . $dstIp . ";");
                            :if ($offenderCount <= $TopN) do={
                                :set offenderInfo ($offenderInfo . "\n  " . $srcIp . \
                                                   " -> " . $dstIp . "");
                            }
                            :if ($Enforce) do={
                                :do {
                                    /ip firewall address-list add list=$ListName address=$srcIp \
                                        timeout=$ListTimeout comment=("rogue-dns to=" . $dstIp);
                                } on-error={};
                            }
                        }
                    }
                }
            }
        }
    }
} on-error={
    :log error "rogue_dns_check: failed to iterate connections";
}

:local body $upstreamAlert;
:if ($offenderCount > 0) do={
    :set body ($body . "\nClient offenders (" . $offenderCount . "):" . $offenderInfo);
    :if ($offenderCount > $TopN) do={
        :set body ($body . "\n  ... (" . ($offenderCount - $TopN) . " more)");
    }
}

:local sig ($upstreamAlert . "|" . $offenderSig);

:if ([:len $body] > 0) do={
    :if ($sig != $RdnsDeliveredSig) do={
        :local MessageText ("\F0\9F\95\B5\EF\B8\8F " . $DeviceName . ": rogue DNS detected" . $body);
        :log warning ("rogue_dns_check: alert offenders=" . $offenderCount . " upstream=" . [:len $upstreamAlert]);
        :local helper "tg_send";
        :if ([:len [:tostr $RdnsSendScript]] > 0) do={ :set helper $RdnsSendScript; }
        :set RdnsSendError "";
        :do {
            :local Send [:parse [/system script get $helper source]];
            :local sent [$Send MessageText=$MessageText MessagePlainText=true];
            :if (([:typeof $sent] != "bool") or ($sent != true)) do={
                :error "delivery not acknowledged";
            }
            :set RdnsDeliveredSig $sig;
        } on-error={
            :set RdnsSendError "helper missing, failed, or did not acknowledge delivery";
            :log error ("rogue_dns_check: " . $RdnsSendError);
        }
    }
} else={
    :if ([:len $RdnsDeliveredSig] > 0) do={
        :log info "rogue_dns_check: cleared - no offenders, upstream OK";
        :set RdnsDeliveredSig "";
    }
    :set RdnsSendError "";
}
