# Re-baseline the firewall_drift detector. Run manually after intentional
# firewall changes; the next firewall_drift run silently captures the new
# baseline. Does NOT touch firewall rules - it only clears the global state
# variable that firewall_drift.lua reads.

:global FW_BASELINE;
:set FW_BASELINE "";
:log info "firewall_drift_baseline: cleared FW_BASELINE; next firewall_drift run will rebaseline.";
