# Kali Red/Blue Lab Cloud-Init

[`kali-vm-init.yaml`](kali-vm-init.yaml) provisions a local Kali VM with
baseline networking commands and curated Kali red-team and blue-team tool
groups. It is intended for an authorized, isolated security lab.

## Result

The configuration:

- upgrades Kali Rolling before installing tools;
- sets the timezone to `Europe/Kyiv`;
- installs baseline diagnostics such as `ping`, `traceroute`, `mtr`, `nmap`,
  `tcpdump`, `tshark`, `socat`, `ethtool`, `nft`, and `conntrack`;
- installs Kali information-gathering, vulnerability, sniffing/spoofing,
  exploitation, and post-exploitation metapackages;
- installs Kali detection, protection, response, and forensics metapackages;
- configures OpenSSH for public-key authentication, with password and direct
  root authentication disabled;
- prepares UFW rules but deliberately leaves UFW disabled; and
- writes `/var/lib/ops-toolbox/kali-vm-init.complete` after successful setup.

The first-boot workload runs in `ops-toolbox-kali-init.service`. Cloud-init
starts that service asynchronously so the VM can become reachable while the
large package installation continues.

## Sizing

Use this as the minimum local VM profile:

| Resource | Minimum | Tested |
| --- | ---: | ---: |
| CPU | 2 cores | 2 ARM64 cores |
| Memory | 4 GB | 4 GB |
| Disk | 64 GB | 64 GB, about 37 GB used after setup |

The package set resolved to more than 1,500 packages in the tested Kali
Rolling snapshot. The tested installation took approximately 40 minutes, but
mirror speed and future Kali dependency changes will affect both time and disk
usage.

## Standard cloud-init usage

Use a Kali image that already contains cloud-init. First validate the file:

```bash
cloud-init schema \
  --config-file linux/cloud-init/kali-vm-init.yaml \
  --annotate
```

Then attach the complete YAML file as cloud-config user-data using your VM or
cloud provider. Monitor the handoff and the longer installation separately:

```bash
sudo cloud-init status --wait --long
sudo systemctl status ops-toolbox-kali-init.service
sudo journalctl -fu ops-toolbox-kali-init.service
sudo kali-lab-status
```

Cloud-init reaching `status: done` only confirms that the systemd handoff
completed. The initialization is finished when this command succeeds:

```bash
sudo test -f /var/lib/ops-toolbox/kali-vm-init.complete
```

`kali-lab-status` condenses service/result state, completion time, disk, SSH,
UFW, and representative tool availability into one read-only report. It exits
`0` when complete, `1` when the initializer failed, `4` while work is still in
progress, and `3` for invalid usage; `--help` works without systemd.

## OrbStack `kali:current` workaround

OrbStack supports `--user-data`, but its stock `kali:current` image did not
contain cloud-init when tested with OrbStack 2.2.3 on 2026-08-12. Passing YAML
directly during `orbctl create` therefore timed out before the machine became
reachable.

The following workflow installs cloud-init first and then performs a real
NoCloud boot with the repository YAML:

```bash
orbctl create --arch arm64 --cpus 2 --memory 4G --disk 64G \
  --user kali kali:current kali-redblue

orbctl run --machine kali-redblue --user root sh -c \
  'export DEBIAN_FRONTEND=noninteractive; \
   apt-get update; \
   apt-get install --yes cloud-init'

orbctl push --machine kali-redblue \
  linux/cloud-init/kali-vm-init.yaml /home/kali/

orbctl run --machine kali-redblue --user root sh -c '
  install -d -m 0755 /var/lib/cloud/seed/nocloud
  install -m 0600 /home/kali/kali-vm-init.yaml \
    /var/lib/cloud/seed/nocloud/user-data
  printf "%s\n" \
    "instance-id: kali-redblue-1" \
    "local-hostname: kali-redblue" \
    > /var/lib/cloud/seed/nocloud/meta-data
  printf "%s\n" "datasource_list: [ NoCloud, None ]" \
    > /etc/cloud/cloud.cfg.d/90-ops-toolbox-datasource.cfg
  printf "%s\n" "network:" "  config: disabled" \
    > /etc/cloud/cloud.cfg.d/91-ops-toolbox-network.cfg
  systemctl mask systemd-networkd-wait-online.service \
    NetworkManager-wait-online.service
  cloud-init clean --logs
'

orbctl restart kali-redblue
```

Follow progress from macOS:

```bash
orbctl run --machine kali-redblue --user root \
  systemctl status ops-toolbox-kali-init.service
orbctl run --machine kali-redblue --user root \
  tail -f /var/log/ops-toolbox-kali-init.log
```

## Verification

Run after the completion marker appears:

```bash
orbctl run --machine kali-redblue --user root sh -c '
  set -eu
  test -f /var/lib/ops-toolbox/kali-vm-init.complete
  systemctl is-active ssh
  ping -c 1 -W 2 1.1.1.1
  command -v ping traceroute mtr nmap tcpdump tshark socat ethtool
  command -v masscan nikto sqlmap ettercap msfconsole weevely
  command -v sentrypeer clamscan ewfacquire autopsy chkrootkit yara
  sshd -t
  test "$(ufw status | head -n 1)" = "Status: inactive"
'
```

Inspect the effective SSH policy rather than only reading configuration files:

```bash
orbctl run --machine kali-redblue --user root sh -c \
  'sshd -T | grep -E "^(permitrootlogin|passwordauthentication|pubkeyauthentication) "'
```

Expected values are `permitrootlogin no`, `passwordauthentication no`, and
`pubkeyauthentication yes`.

## Recovery and repeat runs

The completion marker prevents the expensive initializer from running again
after a normal reboot. To inspect a failed run:

```bash
sudo systemctl status ops-toolbox-kali-init.service
sudo journalctl -u ops-toolbox-kali-init.service --no-pager
sudo tail -n 200 /var/log/ops-toolbox-kali-init.log
sudo df -h /
```

If package configuration was interrupted, repair the package database and
restart the initializer:

```bash
sudo dpkg --configure -a
sudo apt-get --fix-broken install
sudo systemctl restart ops-toolbox-kali-init.service
```

Do not create the completion marker manually. It is written only after package
installation, SSH validation, firewall preparation, and cleanup succeed.

## Automated tests

The Linux Docker suite parses the YAML and checks its package, security,
timeout, service, and idempotency contracts across Debian, Fedora, and Arch:

```bash
LINUX_DISTROS=all ./run-tests.sh linux
```

Docker validates the configuration contract; it does not emulate a Kali VM.
The full runtime validation must be performed with a disposable Kali VM as
described above.
