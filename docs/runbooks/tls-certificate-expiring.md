# A TLS certificate is expired or about to expire

<!-- markdownlint-disable MD033 -->

**When to use:** a service's certificate has expired, a monitor says it is
close, or clients report certificate errors, and you need a check you can
trust before and after the certificate is replaced.

## Symptoms

- Browsers or clients report an expired or invalid certificate.
- `curl` fails with a certificate verification error.
- A monitor or a renewal job warns that a certificate expires soon.

## Before you start

- A shell on a Linux machine with `openssl`. Without `openssl` the check is
  exit `2`; `--help` and a missing `--file` still answer without it.
- The PEM paths or the `HOST[:PORT]` names you actually serve. The script
  checks the **leaf** certificate only: the first certificate in a PEM
  bundle, or the one the server presents. It never walks `/etc/ssl/certs`
  (passing a directory is a `[FAIL]`), and it does not speak STARTTLS, so a
  port that upgrades a plain-text connection will not hand it a certificate.
- The script. Work from a clone of the repository, or copy
  `linux/tls_expiry.sh` onto the machine; it works on its own. See
  [Installation and usage](../getting-started/usage.md).
- More on the Linux scripts and their caveats is on the
  [Linux page](../platforms/linux.md).

## Report

<span class="stage stage-report">read-only</span>

!!! report "Nothing changes in this step"
    `tls_expiry.sh` only reads certificates. It changes nothing on the
    machine or the server.

Check the files you serve, the endpoints clients reach, or both:

```{ .bash .rpt-report title="Report" }
./linux/tls_expiry.sh --file /etc/letsencrypt/live/NAME/fullchain.pem
./linux/tls_expiry.sh --host example.com --host example.com:8443
./linux/tls_expiry.sh --file ./leaf.pem --days 14
```

| Option | Meaning |
| --- | --- |
| `--file PATH` | A PEM to inspect. Repeatable; a comma-separated list also works. Only the first certificate of a bundle is read. |
| `--host HOST[:PORT]` | Fetch the leaf over TLS. Default port `443`; repeatable. |
| `--days N` | Warn this many days before expiry. Default `30`, from `0` to `3650`. |
| `--fail-on LEVEL` | When to exit `1`: `expired` (the default), `warn`, or `never`. See below. |
| `--quiet` | Print only warnings and failures, plus the section headings and the summary. |

For `--host`, the script runs `openssl s_client` with the host name as SNI,
limited to 10 seconds when `timeout` is installed, and reads the certificate
the server presents. Checking the host as well as the file catches a service
that was never reloaded after the file was renewed.

Each certificate gets one of three outcomes:

| Outcome | What it means |
| --- | --- |
| `[pass]` | Valid for longer than `--days`. The line shows the expiry date and the days left. |
| `[warn]` | Still valid, but inside the window. The hint under it says "renew before the 30d window closes" (with your `--days`). |
| `[FAIL]` | Already expired ("replace the leaf; clients already reject it"), or the file is missing, a directory, or not a readable PEM. |

The run ends with a summary line of pass, warn, fail and skip counts.
Illustrative output (yours will differ):

```text
== hosts ==
  [warn] example.com expires Nov  2 12:00:00 2026 GMT (12d)
         renew before the 30d window closes
  [warn] example.com:8443: could not fetch a leaf certificate
         openssl s_client -connect example.com:8443 -servername example.com

== summary ==
  0 pass  2 warn  0 fail  0 skip
```

### Decide

Exit codes: `0` clean, `1` findings at or above `--fail-on`, `2` preflight
failed (not Linux, or no `openssl`), `3` bad arguments.

| `--fail-on` | Exits `1` when |
| --- | --- |
| `expired` (default) | Any `[FAIL]`: an expired certificate, a file that is missing, a directory or not a readable PEM, or a `--host` that is not `HOST` or `HOST:PORT`. |
| `warn` | Any `[FAIL]` or any `[warn]`: inside the window, or a host that could not be fetched. |
| `never` | Never, for certificate findings. Usage errors (`3`) and a missing `openssl` (`2`) still exit nonzero; read the output. |

!!! warning "An unreachable host is only a warning"
    When `--host` cannot fetch a certificate (DNS, firewall, the service is
    down, or the port speaks STARTTLS), the result is a `[warn]` "could not
    fetch a leaf certificate", **not** a failure. With the default
    `--fail-on expired` the run still exits `0`. Use `--fail-on warn` in any
    check that has to notice it, and run the `openssl s_client` command the
    script prints under the warning to see the real error.

To tell "the network or DNS is broken" apart from "the certificate is bad",
run `./linux/net_doctor.sh --probe HOST`. Its sections are interfaces,
routes, dns, listen and probe; the probe resolves the host and tries a TCP
connection on 443, then 80.

## Preview

<span class="stage stage-preview">dry run</span>

!!! preview "Nothing to preview: this runbook has no scripted change"
    `tls_expiry.sh` has no mode that changes anything, so it has no dry run.

The preview for this incident is checking the **new** certificate before it
goes live. When the renewed PEM is on disk, and before you reload the
service, check that file:

```{ .bash .rpt-preview title="Check the new file" }
./linux/tls_expiry.sh --file /path/to/NEW/fullchain.pem --fail-on warn
```

A `[pass]` with the new expiry date only means the file has not expired
(the script runs `openssl x509 -checkend`). It does not check the hostname
or SAN, the chain or issuer, `notBefore` or the private key. Check those
separately before you deploy:

```{ .bash .rpt-preview title="Check the rest of the new file" }
openssl x509 -in /path/to/NEW/fullchain.pem -noout -subject -issuer -dates -ext subjectAltName
openssl verify -untrusted /path/to/NEW/fullchain.pem /path/to/NEW/fullchain.pem
openssl x509 -in /path/to/NEW/fullchain.pem -noout -pubkey | openssl sha256
openssl pkey -in /path/to/NEW/privkey.pem -pubout | openssl sha256
```

The two `sha256` lines must be identical, the SAN list must include your
hostname, and `notBefore` must not be in the future.

## Apply

<span class="stage stage-apply">changes things</span>

!!! apply "Not scripted by this repository"
    Issuing or renewing the certificate (an ACME client, an internal CA, a
    cloud load balancer) and reloading the service are done with your own
    tooling. This toolbox only verifies the result.

## Verify

<span class="stage stage-report">read-only</span>

Check what clients see, with the window as a failure:

```{ .bash .rpt-report title="Verify" }
./linux/tls_expiry.sh --host example.com --days 30 --fail-on warn
```

Success is a `[pass]` line with the new expiry date and exit `0`. That
confirms only the expiry and that the service was reloaded. A `[warn]` here
means either the old certificate is still being served (the service was not
reloaded) or the host could not be reached. The script does not verify the
chain or that the certificate matches the host name, so a certificate with
the wrong name or a missing intermediate still passes.

For that, run a live check with verification on:

```{ .bash .rpt-report title="Verify chain and name" }
openssl s_client -connect example.com:443 -servername example.com \
    -verify_hostname example.com -verify_return_error </dev/null
```

A pass shows `Verify return code: 0 (ok)` near the end of the output. With
`-verify_return_error` a failure aborts the handshake and prints a `verify
error:` line (for example a name mismatch or an unable-to-get-local-issuer
error).

For a cron job or monitor that covers every certificate on the machine,
quote the glob so the script expands it itself:

```{ .bash .rpt-report title="Verify every file" }
./linux/tls_expiry.sh --file '/etc/letsencrypt/live/*/fullchain.pem' --fail-on warn
```

The script expands a quoted `*`, `?` or `[` pattern. A directory name that
contains spaces will not match; pass those files one by one.

## Roll back

`tls_expiry.sh` changed nothing, so it has nothing to roll back.

General advice, not a script feature: keep the previous certificate and key
until the Verify step passes, so you can put them back and reload if the new
one is wrong. An already expired certificate cannot be rolled back to; the
only way forward is a valid new one.

## Related

- [Linux platform page](../platforms/linux.md)
- [`linux/` folder README](https://github.com/greenblacked/ops-toolbox/blob/master/linux/README.md)
- [Scripts overview](../scripts/index.md)
- The RouterOS counterpart that watches a router's certificate store is
  [`mikrotik/features/cert_expiry_watch.lua`](https://github.com/greenblacked/ops-toolbox/blob/master/mikrotik/features/cert_expiry_watch.lua).

<!-- markdownlint-enable MD033 -->
