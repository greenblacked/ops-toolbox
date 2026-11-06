- The destructive RouterOS tests refuse to run unless the target proves it is
  the disposable QEMU CHR lab, by its board name and its QEMU test NIC, so
  they cannot be pointed at a real router by mistake. The CHR image the lab
  boots is verified against its SHA-256 before the container is built.
