# Rogue DNS detector. Two checks per run:
#   1. Upstream sanity: resolve a control hostname (default "dns.cloudflare.com")
#      and verify it resolves to an IP listed in :global DNS_EXPECTED. A
#      mismatch suggests upstream hijack, DoH/DoT leak, or a wrong resolver.
#   2. Client behavior: scan /ip firewall connection for outbound dst-port=53
#      flows whose destination is neither the router itself nor a resolver in
#      :global DNS_ALLOWED_RESOLVERS. Aggregates the offenders by source IP.
#
# Schedule via /system scheduler with interval=10m.
#
# Globals:
#   DNS_EXPECTED            ";1.1.1.1;1.0.0.1;..." - any IP that the control
#                           hostname is allowed to resolve to.
#   DNS_ALLOWED_RESOLVERS   ";1.1.1.1;8.8.8.8;..." - resolvers clients are
#                           allowed to talk to. The router's own IPs are added
#                           automatically.
#   RDNS_LAST_FLAG          signature of the last alert; suppresses repeats.
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
:local CtrlHost     "dns.cloudflare.com";
:local ListName     "rogue-dns-clients";
:local ListTimeout  "1h";
:local TopN         5;

:global DNS_EXPECTED;
:global DNS_ALLOWED_RESOLVERS;
:global RDNS_LAST_FLAG;

:if ([:typeof $DNS_EXPECTED] != "str") do={ :set DNS_EXPECTED ";1.1.1.1;1.0.0.1;"; }
:if ([:typeof $DNS_ALLOWED_RESOLVERS] != "str") do={
    :set DNS_ALLOWED_RESOLVERS ";1.1.1.1;1.0.0.1;8.8.8.8;8.8.4.4;";
}
:if ([:typeof $RDNS_LAST_FLAG] != "str") do={ :set RDNS_LAST_FLAG ""; }

:local expected $DNS_EXPECTED;
:if ([:pick $expected 0 1] != ";") do={ :set expected (";" . $expected); }
:if ([:pick $expected ([:len $expected] - 1) [:len $expected]] != ";") do={ :set expected ($expected . ";"); }

:local allowed $DNS_ALLOWED_RESOLVERS;
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
            :set upstreamAlert ("%0A<b>Upstream sanity:</b> <code>" . $CtrlHost . \
                                "</code> -> <code>" . $resolvedStr . "</code> (not in DNS_EXPECTED)");
        }
    }
} on-error={
    :set upstreamAlert ("%0A<b>Upstream sanity:</b> resolve(" . $CtrlHost . ") failed");
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
                                :set offenderInfo ($offenderInfo . "%0A  <code>" . $srcIp . \
                                                   "</code> -> <code>" . $dstIp . "</code>");
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
    :set body ($body . "%0A<b>Client offenders (" . $offenderCount . "):</b>" . $offenderInfo);
    :if ($offenderCount > $TopN) do={
        :set body ($body . "%0A  ... (" . ($offenderCount - $TopN) . " more)");
    }
}

:local sig ($upstreamAlert . "|" . $offenderSig);

:if ([:len $body] > 0) do={
    :if ($sig != $RDNS_LAST_FLAG) do={
        :local MessageText ("\F0\9F\95\B5\EF\B8\8F <b>" . $DeviceName . ":</b> rogue DNS detected" . $body);
        :log warning ("rogue_dns_check: alert offenders=" . $offenderCount . " upstream=" . [:len $upstreamAlert]);
        :do {
            :local Send [:parse [/system script get tg_send source]];
            $Send MessageText=$MessageText;
        } on-error={ :log error "rogue_dns_check: tg_send unavailable"; }
        :set RDNS_LAST_FLAG $sig;
    }
} else={
    :if ([:len $RDNS_LAST_FLAG] > 0) do={
        :log info "rogue_dns_check: cleared - no offenders, upstream OK";
        :set RDNS_LAST_FLAG "";
    }
}
