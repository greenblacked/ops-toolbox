- `linux/net_doctor.sh` has a links section that explains a slow or flaky
  network from sysfs: error and drop counters past 0.1% of a NIC's packets,
  half duplex or a 100 Mb/s link, carrier flaps, a bond with a slave down,
  an uplink MTU below 1500, and a default gateway that no longer answers
  ARP. Virtual interfaces are counted, not graded, and `--skip-links` leaves
  the section out. It reads files and `ip neigh` only.
