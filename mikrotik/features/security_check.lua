# Read-only security posture scan for RouterOS 7.x.
# It reports observations and uncertainty; it never changes firewall, DNS,
# services, Wi-Fi, users, backups, packages, or the update channel.
#
# Schedule with /system scheduler. Optional globals:
#   SecurityManagementList      intended interface-list for MAC management
#   SecurityManagementNetworks expected /ip service source restriction string
#   SecurityManagementWifi      management Wi-Fi interface name
#   SecurityReportAlways        true = send even when unchanged
#   SecuritySendScript          Telegram helper name, default tg_send_new
#
# State:
#   SecLastFp       most recent observed fingerprint
#   SecDeliveredFp  last fingerprint Telegram acknowledged
#   SecSendError    last delivery error
#   SecReport       named array of the latest findings
#
# No :local or :global variable name below contains an underscore because
# RouterOS 7.24 rejects that shape at execution time on affected paths.

:global OpsToolboxPaused;
:if (([:typeof $OpsToolboxPaused] = "bool") and $OpsToolboxPaused) do={ :return ""; }

:global SecurityManagementList;
:global SecurityManagementNetworks;
:global SecurityManagementWifi;
:global SecurityReportAlways;
:global SecuritySendScript;
:global SecLastFp;
:global SecDeliveredFp;
:global SecSendError;
:global SecReport;

:local priorObserved [:tostr $SecLastFp];
:local checks [:toarray ""];
:local evidence "security-v2|";

# Management services. /ip service restrictions and firewall filtering are
# different layers. An empty service restriction does not prove WAN exposure.
:do {
    :foreach sid in=[/ip service find] do={
        :local sn [/ip service get $sid name];
        :if (($sn = "telnet") or ($sn = "ftp") or ($sn = "www") or              ($sn = "www-ssl") or ($sn = "ssh") or ($sn = "winbox") or              ($sn = "api") or ($sn = "api-ssl")) do={
            :do {
                :local disabled [/ip service get $sid disabled];
                :local port [/ip service get $sid port];
                :local acl "";
                :do {
                    :set acl [:tostr [/ip service get $sid available-from]];
                } on-error={
                    :set acl [:tostr [/ip service get $sid address]];
                }

                :set evidence ($evidence . $sn . ":" . $disabled . ":" . $port . ":" . $acl . "|");

                :if ($disabled = true) do={
                    :set ($checks->("service-" . $sn)) ("[INFO] " . $sn . " disabled.");
                } else={
                    :local finding ("[INFO] " . $sn . " enabled on port " . $port .                         "; service source restriction is configured. Reachability not tested.");

                    :if (($acl = "") or ([:find $acl "0.0.0.0/0"] != nil) or                         ([:find $acl "::/0"] != nil)) do={
                        :set finding ("[UNKNOWN] " . $sn .                             " has no effective /ip service source restriction. " .                             "Input firewall may still restrict access; WAN exposure was not tested.");
                    }

                    :if (([:len [:tostr $SecurityManagementNetworks]] > 0) and                         ($acl != [:tostr $SecurityManagementNetworks])) do={
                        :set finding ("[WARN] " . $sn .                             " source restriction differs from the configured management policy. " .                             "Compare the actual subnets before changing it.");
                    }

                    :if (($sn = "telnet") or ($sn = "ftp") or ($sn = "www") or ($sn = "api")) do={
                        :set finding ($finding . " Service is unencrypted; disable it if unused.");
                    }

                    :set ($checks->("service-" . $sn)) $finding;
                }
            } on-error={
                :set ($checks->("service-" . $sn)) ("[UNKNOWN] Could not inspect " . $sn . ".");
            }
        }
    }
} on-error={
    :set ($checks->"services") "[UNKNOWN] Could not enumerate management services.";
}

# DNS/DoH. A local resolver is normal for LAN clients and is not, by itself,
# an open-resolver finding.
:do {
    :local resolver [/ip dns get allow-remote-requests];
    :local servers [:tostr [/ip dns get servers]];
    :local dynamicServers [:tostr [/ip dns get dynamic-servers]];
    :local doh [:tostr [/ip dns get use-doh-server]];
    :local verify [/ip dns get verify-doh-cert];

    :set evidence ($evidence . "dns:" . $resolver . ":" . $servers . ":" .         $dynamicServers . ":" . $doh . ":" . $verify . "|");

    :if ($resolver = true) do={
        :set ($checks->"dns-resolver")             "[INFO] Local DNS resolver enabled. Valid for LAN clients; WAN/guest TCP+UDP 53 reachability was not tested.";
    } else={
        :set ($checks->"dns-resolver") "[INFO] Local DNS resolver disabled.";
    }

    :if (($doh != "") and ($verify != true)) do={
        :set ($checks->"dns-doh")             "[HIGH] DoH is configured without certificate verification. Review trust and clock before enabling verification.";
    } else={
        :set ($checks->"dns-doh")             "[INFO] DoH certificate setting checked. DNS enforcement and resolver reachability were not tested.";
    }
} on-error={
    :set ($checks->"dns") "[UNKNOWN] Could not inspect DNS/DoH settings.";
}

# IPv4 input filtering. Count only enabled, non-invalid drop/reject rules, but
# never claim that their presence proves isolation. Order, jumps, NAT, bridge
# forwarding and interface-list expansion still matter.
:do {
    :local enabled 0;
    :local drops 0;

    :foreach row in=[/ip firewall filter print as-value where chain=input] do={
        :foreach key,value in=$row do={
            :if (($key != "bytes") and ($key != "packets") and                 ($key != "comment") and ($key != ".id")) do={
                :set evidence ($evidence . $key . "=" . [:tostr $value] . ";");
            }
        }
        :set evidence ($evidence . "|");

        :if ((($row->"disabled") != true) and (($row->"invalid") != true)) do={
            :set enabled ($enabled + 1);
            :if ((($row->"action") = "drop") or (($row->"action") = "reject")) do={
                :set drops ($drops + 1);
            }
        }
    }

    :if ($drops = 0) do={
        :set ($checks->"firewall-ipv4")             "[WARN] No enabled IPv4 input drop/reject found. Review the input policy; WAN exposure is not inferred automatically.";
    } else={
        :set ($checks->"firewall-ipv4") ("[UNKNOWN] IPv4 input has " . $enabled .             " enabled rules and " . $drops .             " enabled drops/rejects. Rule order and actual reachability still require review.");
    }
} on-error={
    :set ($checks->"firewall-ipv4") "[UNKNOWN] Could not inspect IPv4 input filtering.";
}

:do {
    :local disabled [/ipv6 settings get disable-ipv6];
    :if ($disabled = true) do={
        :set ($checks->"firewall-ipv6")             "[INFO] IPv6 is disabled in settings; post-reboot effective state was not independently tested.";
    } else={
        :foreach row in=[/ipv6 firewall filter print as-value where chain=input] do={
            :foreach key,value in=$row do={
                :if (($key != "bytes") and ($key != "packets") and                     ($key != "comment") and ($key != ".id")) do={
                    :set evidence ($evidence . "v6:" . $key . "=" . [:tostr $value] . ";");
                }
            }
            :set evidence ($evidence . "|");
        }
        :set ($checks->"firewall-ipv6")             "[UNKNOWN] IPv6 enabled. Input-rule presence alone cannot prove management or DNS isolation.";
    }
} on-error={
    :set ($checks->"firewall-ipv6") "[UNKNOWN] Could not inspect IPv6 state/filtering.";
}

# Interface lists and bridge ports affect management reachability even when
# input rules stay unchanged. Observe the topology without pretending to
# simulate forwarding.
:do {
    :foreach row in=[/interface list print as-value] do={
        :set evidence ($evidence . "list:" . ($row->"name") . ":" .             ($row->"include") . ":" . ($row->"exclude") . "|");
    }
    :foreach row in=[/interface list member print as-value] do={
        :set evidence ($evidence . "member:" . ($row->"list") . ":" .             ($row->"interface") . "|");
    }
    :foreach row in=[/interface bridge port print as-value] do={
        :set evidence ($evidence . "bridge=" . [:tostr ($row->"bridge")] .             ";interface=" . [:tostr ($row->"interface")] .             ";disabled=" . [:tostr ($row->"disabled")] .             ";pvid=" . [:tostr ($row->"pvid")] . "|");
    }
} on-error={
    :set ($checks->"management-topology")         "[UNKNOWN] Interface-list or bridge observations were incomplete.";
}

:do {
    :local actual [/tool mac-server mac-winbox get allowed-interface-list];
    :set evidence ($evidence . "mac-winbox:" . $actual . "|");

    :if ($actual = "none") do={
        :set ($checks->"mac-winbox") "[INFO] MAC WinBox disabled.";
    } else={
        :set ($checks->"mac-winbox")             "[UNKNOWN] MAC WinBox interface list observed; list membership and bridge reachability were not fully evaluated.";
        :if (($actual = "all") or ($actual = "dynamic")) do={
            :set ($checks->"mac-winbox") "[WARN] MAC WinBox uses a broad interface list.";
        }
        :if (([:len [:tostr $SecurityManagementList]] > 0) and             ($actual != $SecurityManagementList)) do={
            :set ($checks->"mac-winbox")                 "[WARN] MAC WinBox interface list differs from the configured management policy.";
        }
    }
} on-error={
    :set ($checks->"mac-winbox") "[UNKNOWN] Could not inspect MAC WinBox.";
}

:do {
    :local actual [/tool mac-server get allowed-interface-list];
    :set evidence ($evidence . "mac-server:" . $actual . "|");
    :if ($actual = "none") do={
        :set ($checks->"mac-server") "[INFO] MAC server disabled.";
    } else={
        :set ($checks->"mac-server")             "[UNKNOWN] MAC server interface list observed; effective L2 reachability was not evaluated.";
        :if (($actual = "all") or ($actual = "dynamic")) do={
            :set ($checks->"mac-server") "[WARN] MAC server uses a broad interface list.";
        }
    }
} on-error={
    :set ($checks->"mac-server") "[UNKNOWN] Could not inspect MAC server.";
}

:do {
    :local actual [/ip neighbor discovery-settings get discover-interface-list];
    :set evidence ($evidence . "discovery:" . $actual . "|");
    :set ($checks->"discovery")         "[INFO] Neighbor discovery interface list observed; membership was not fully evaluated.";
    :if (($actual = "all") or ($actual = "dynamic")) do={
        :set ($checks->"discovery") "[WARN] Neighbor discovery uses a broad interface list.";
    }
} on-error={
    :set ($checks->"discovery") "[UNKNOWN] Could not inspect neighbor discovery.";
}

# Wi-Fi is optional on CHR. Parse the menu at runtime so an absent wifi-qcom
# package cannot abort the rest of the report. Never include SSIDs or secrets.
:do {
    :local WifiRead [:parse ":return [/interface wifi print as-value];"];
    :local rows [$WifiRead];
    :set ($checks->"wifi")         "[UNKNOWN] Wi-Fi observations read; inherited WPA/MFP policy is not fully evaluated.";

    :foreach row in=$rows do={
        :local auth [:tostr ($row->"security.authentication-types")];
        :local mfp [:tostr ($row->"security.management-protection")];
        :set evidence ($evidence . "wifi:" . ($row->"name") . ":" .             ($row->"disabled") . ":" . $auth . ":" . $mfp . "|");

        :if (([:len [:tostr $SecurityManagementWifi]] > 0) and             (($row->"name") = $SecurityManagementWifi) and             (($row->"disabled") != true)) do={
            :if (([:find $auth "wpa2-psk"] != nil) or                 ([:find $auth "wpa-psk"] != nil)) do={
                :set ($checks->"wifi")                     "[WARN] Management Wi-Fi explicitly permits pre-WPA3 authentication. Review effective profile inheritance before changing it.";
            }
        }
    }
} on-error={
    :set ($checks->"wifi")         "[UNKNOWN] Wi-Fi menu unavailable or unreadable; this is not a successful Wi-Fi security check.";
}

:do {
    :local flagged [/system device-mode get flagged];
    :if ($flagged = true) do={
        :set ($checks->"device-mode")             "[HIGH] Device is flagged. Investigate before clearing it; the flag is not itself proof of compromise.";
    } else={
        :set ($checks->"device-mode")             "[INFO] Device not flagged. This is not proof of an uncompromised router.";
    }
} on-error={
    :set ($checks->"device-mode") "[UNKNOWN] Could not read the device-mode flag.";
}

:do {
    :set ($checks->"users")         "[INFO] Default admin account absent or disabled; other accounts were not audited.";
    :foreach uid in=[/user find name=admin] do={
        :if ([/user get $uid disabled] != true) do={
            :set ($checks->"users")                 "[WARN] Default admin account enabled. Verify a working alternative before changing accounts.";
        }
    }
} on-error={
    :set ($checks->"users") "[UNKNOWN] Could not inspect the default admin account.";
}

:do {
    :if ([/snmp get enabled] = true) do={
        :set ($checks->"snmp")             "[WARN] SNMP enabled. Review protocol version, communities and permitted source networks.";
        :if ([:len [/snmp community find name=public]] > 0) do={
            :set ($checks->"snmp")                 "[HIGH] SNMP enabled with the default public community. Review effective access.";
        }
    } else={
        :set ($checks->"snmp")             "[INFO] SNMP disabled; inactive community objects do not expose a running service.";
    }
} on-error={
    :set ($checks->"snmp") "[UNKNOWN] Could not inspect SNMP.";
}

:do {
    :if ([/ip upnp get enabled] = true) do={
        :set ($checks->"upnp")             "[WARN] UPnP enabled; clients may request port mappings. Review intended use.";
    } else={
        :set ($checks->"upnp") "[INFO] UPnP disabled.";
    }
} on-error={
    :set ($checks->"upnp") "[UNKNOWN] Could not inspect UPnP.";
}

# Fingerprint named observations. Counters and scan timestamps are intentionally
# absent so normal traffic does not create a new alert every run.
:local MessageText "RouterOS security scan: configuration observations\n";
:local omitted false;

:foreach key,value in=$checks do={
    :set evidence ($evidence . $key . "=" . $value . "|");
}

# Prioritise actionable/uncertain findings before informational lines so the
# Telegram size ceiling cannot hide the important part.
:foreach level in={"[HIGH]";"[WARN]";"[UNKNOWN]";"[INFO]"} do={
    :foreach key,value in=$checks do={
        :if ([:pick $value 0 [:len $level]] = $level) do={
            :if ([:len ($MessageText . $value)] < 3400) do={
                :set MessageText ($MessageText . $value . "\n");
            } else={
                :set omitted true;
            }
        }
    }
}

:if ($omitted) do={
    :set MessageText ($MessageText .         "Additional observations omitted from Telegram; inspect SecReport locally.\n");
}

:set SecReport $checks;
:set SecLastFp $evidence;

# Suppress only a fingerprint that was actually delivered. A failed Telegram
# send must retry on the next run.
:if (($priorObserved != "") and ($SecDeliveredFp = $evidence) and     ($SecurityReportAlways != true) and ([:len [:tostr $SecSendError]] = 0)) do={
    :return "";
}

:local helper "tg_send_new";
:if ([:len [:tostr $SecuritySendScript]] > 0) do={
    :set helper $SecuritySendScript;
}

:set SecSendError "";
:do {
    :local Send [:parse [/system script get $helper source]];
    :local sent [$Send MessageText=$MessageText MessagePlainText=true];
    :if (([:typeof $sent] = "bool") and (!$sent)) do={
        :error "helper returned false";
    }
    :set SecDeliveredFp $evidence;
} on-error={
    :set SecSendError         "helper missing, unparseable, returned false, or raised while sending; delivery not acknowledged";
    :log error ("security_check: " . $SecSendError);
}
