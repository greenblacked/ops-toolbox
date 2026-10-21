- `windows/setup/hardening_audit.ps1` grades a Windows machine's security
  posture with the verdicts, `-FailOn` and exit codes of
  `linux/hardening_audit.sh`: firewall profiles, SMBv1, LLMNR, Remote Desktop
  and Network Level Authentication, WinRM `TrustedHosts`, the OpenSSH server,
  UAC, autologon and a clear-text `DefaultPassword`, the Guest account,
  broad principals among the local Administrators, Secure Boot, the TPM, LSA
  protection, virtualization-based security, Defender, script block logging
  and patch age. It prints the fix under every finding and never applies
  one; checks that need elevation are skipped, not failed, without it.
  It follows `Include` lines in `sshd_config` as sshd does, first value
  wins, and reports a setting it could not read as not judged rather than
  as a pass.
