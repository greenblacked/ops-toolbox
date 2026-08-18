#!/bin/bash
# QEMU + MikroTik CHR in Docker (user-mode networking). Based on the pattern from
# https://github.com/tikoci/restraml — port forwards match the compose maps.
set -euo pipefail

KVM_OPTS=()
CPU_OPT="qemu64"
if [ -e /dev/kvm ] && grep -q -e vmx -e svm /proc/cpuinfo 2>/dev/null; then
  echo "[chr] KVM available — hardware acceleration on."
  KVM_OPTS=(-enable-kvm -machine "accel=kvm")
  CPU_OPT="host"
else
  echo "[chr] KVM not available — software emulation (TCG)."
  echo "[chr] First boot under TCG (esp. linux/amd64 on Apple Silicon) can take many minutes."
fi

MEM_MB="${CHR_MEM_MB:-512}"
echo "[chr] Booting RouterOS CHR ${ROUTEROS_VERSION:-?} (image=${ROUTEROS_IMAGE:-?}, mem=${MEM_MB}MB)…"

exec qemu-system-x86_64 \
  -name "chr-${ROUTEROS_VERSION:-unknown}" \
  -serial mon:stdio \
  -nographic \
  -m "${MEM_MB}" \
  -smp "${CHR_CPUS:-1}" \
  -cpu "${CPU_OPT}" \
  "${KVM_OPTS[@]}" \
  -drive "file=/routeros/${ROUTEROS_IMAGE},format=qcow2,if=virtio" \
  -netdev "user,id=net0,hostfwd=tcp::22-:22,hostfwd=tcp::23-:23,hostfwd=tcp::80-:80,hostfwd=tcp::443-:443,hostfwd=tcp::8728-:8728,hostfwd=tcp::8729-:8729,hostfwd=tcp::8291-:8291,hostfwd=tcp::5900-:5900" \
  -device virtio-net-pci,netdev=net0 \
  "$@"
