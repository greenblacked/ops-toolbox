- `linux/system_doctor.sh` has a pressure section that reads the kernel's
  stall information for CPU, memory and I/O instead of trusting load
  average, and warns past `--max-psi` percent of the last minute. It also
  reports file-handle use, a filling connection tracking table, thread and
  PID headroom, and zombie or uninterruptible processes, and names the top
  memory and CPU consumers when a stall was found. Every probe skips when
  its file is missing, and the script still never exits 1.
