# MAC allowlist for DHCP leases. Iterates /ip dhcp-server lease and flags any
# lease whose MAC is not on the allowlist. Schedule via /system scheduler with
# interval=5m.
#
# Allowlist sources (any one of them whitelists a lease):
#   - Global :global MAC_ALLOWLIST set in startup. Format is a delimited string,
#     e.g. ";aa:bb:cc:dd:ee:ff;11:22:33:44:55:66;". Leading/trailing ";" optional.
#   - Per-lease comment containing the literal substring "#allow".
#
# Globals:
#   MAC_ALLOWLIST           operator-managed allowlist (see above).
#   MACALLOW_LAST_FLAG      delimited set of unknown MACs from the last alert,
#                           used to suppress repeated alerts while the same set
#                           of unknown devices remains.
#
# Action mode:
#   Enforce=true       (default) tags unknown lease IPs into address-list dhcp-unknown.
#   BlockUnknown=true  (off by default) idempotently installs a forward-chain
#                      drop rule with comment "mac-allowlist-block" sourced from
#                      that address-list. The rule is appended at the end - move
#                      it manually into the right position in /ip firewall filter.
#
# Fail-safe: if MAC_ALLOWLIST is empty the script does nothing. This prevents an
# unconfigured allowlist from accidentally locking every device out.

# Fleet-wide maintenance switch; router_doctor.py reports when it is active.
:global OpsToolboxPaused;
:if (([:typeof $OpsToolboxPaused] = "bool") and $OpsToolboxPaused) do={ :return ""; }

:local DeviceName [/system identity get name];

:local Enforce         true;
:local BlockUnknown    false;
:local ListName        "dhcp-unknown";
:local ListTimeout     "1d";
:local DropRuleComment "mac-allowlist-block";

:global MAC_ALLOWLIST;
:global MACALLOW_LAST_FLAG;

:if ([:typeof $MAC_ALLOWLIST] != "str") do={ :set MAC_ALLOWLIST ""; }
:if ([:typeof $MACALLOW_LAST_FLAG] != "str") do={ :set MACALLOW_LAST_FLAG ""; }

:if ([:len $MAC_ALLOWLIST] = 0) do={
    :log info "mac_allowlist_dhcp: MAC_ALLOWLIST empty - skipping (fail-safe)";
    :return "";
}

:local normAllow $MAC_ALLOWLIST;
# Lease MAC addresses are commonly uppercase; README examples are often
# lowercase. Compare case-insensitively so either spelling works.
:do { :set normAllow [:convert $normAllow transform=lc]; } on-error={};
:if ([:pick $normAllow 0 1] != ";") do={ :set normAllow (";" . $normAllow); }
:if ([:pick $normAllow ([:len $normAllow] - 1) [:len $normAllow]] != ";") do={ :set normAllow ($normAllow . ";"); }

:local unknownInfo "";
:local unknownCount 0;
:local unknownSig ";";

:do {
    :foreach lid in=[/ip dhcp-server lease find] do={
        :local mac [/ip dhcp-server lease get $lid mac-address];
        :local addr [/ip dhcp-server lease get $lid address];
        :local host "";
        :do { :set host [/ip dhcp-server lease get $lid host-name]; } on-error={};
        :local cmt "";
        :do { :set cmt [/ip dhcp-server lease get $lid comment]; } on-error={};

        :local macCanon $mac;
        :do { :set macCanon [:convert $mac transform=lc]; } on-error={};

        :local allowed false;
        :if ([:find $normAllow (";" . $macCanon . ";")] != nil) do={ :set allowed true; }
        :if ([:find $cmt "#allow"] != nil) do={ :set allowed true; }

        :if (!$allowed) do={
            :set unknownCount ($unknownCount + 1);
            :local hostShown $host;
            :if ([:len $hostShown] = 0) do={ :set hostShown "?"; }
            :set unknownInfo ($unknownInfo . "%0A  <code>" . $mac . "</code>  ip=" . $addr . " host=" . $hostShown);
            :set unknownSig ($unknownSig . $mac . ";");
            :if ($Enforce) do={
                :do {
                    /ip firewall address-list add list=$ListName address=$addr timeout=$ListTimeout \
                        comment=("mac-allowlist unknown mac=" . $mac);
                } on-error={};
            }
        }
    }
} on-error={
    :log error "mac_allowlist_dhcp: failed to iterate leases";
    :return "";
}

# Optionally install a single drop rule sourced from the address-list. We only
# add when BlockUnknown is true AND there's at least one unknown lease. The rule
# is created idempotently by checking for the exact comment first, and appended
# to the end of /ip firewall filter - operators are expected to move it into the
# correct position in their forward chain manually.
:if ($Enforce and $BlockUnknown and ($unknownCount > 0)) do={
    :local existing [/ip firewall filter find comment=$DropRuleComment];
    :if ([:len $existing] = 0) do={
        :do {
            /ip firewall filter add chain=forward action=drop \
                src-address-list=$ListName comment=$DropRuleComment;
            :log warning "mac_allowlist_dhcp: installed drop rule (review position in /ip firewall filter)";
        } on-error={ :log error "mac_allowlist_dhcp: failed to install drop rule"; }
    }
}

# Re-alert only when the set of unknown MACs changes from the previous alert.
:if ($unknownSig != $MACALLOW_LAST_FLAG) do={
    :if ($unknownCount > 0) do={
        :local MessageText ("\E2\9A\A0\EF\B8\8F <b>" . $DeviceName . ":</b> DHCP MAC allowlist alert" . \
                           "%0A<b>Unknown MACs (" . $unknownCount . "):</b>" . $unknownInfo);
        :log warning ("mac_allowlist_dhcp: unknown MACs detected count=" . $unknownCount);
        :do {
            :local Send [:parse [/system script get tg_send source]];
            $Send MessageText=$MessageText;
        } on-error={ :log error "mac_allowlist_dhcp: tg_send unavailable"; }
    } else={
        :log info "mac_allowlist_dhcp: cleared - all leases allowlisted";
    }
    :set MACALLOW_LAST_FLAG $unknownSig;
}
