- `k8s-toolbox/kubectl_cert_expiry.sh` reports expired and expiring TLS
  certificates in `kubernetes.io/tls` Secrets, soonest first, so "which
  certificate expires next" has an answer before it becomes an outage.
  `--warn-days` sets the window (30 by default) and `--cert-manager` also
  reads cert-manager Certificates, including any whose `Ready` condition is
  False. A missing or unreadable `tls.crt` is a finding, the private key is
  never read, printed or passed to `openssl`, and exit `4` means nothing
  expires within the window, so it can run from cron.
