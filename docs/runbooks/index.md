# Runbooks

A runbook is a short, ordered procedure for one operational incident. Each
one is built only from scripts this repository ships, and it follows the
same order as the rest of the toolbox: **report** what is wrong, **preview**
what the fix would do, then **apply** it and **verify**.

A runbook does not replace the script's own `--help`, which stays the
authoritative list of flags. It strings the right commands together for one
situation and says plainly what can and cannot be undone.

## How a runbook is laid out

Every page uses the same headings, so you can find the step you need in a
hurry.

| Section | What it holds |
| --- | --- |
| When to use | One line: the situation this page is for. |
| Symptoms | What you see when it applies. |
| Before you start | Access you need, how to get the scripts, and a link to the platform page. |
| Report | Read-only commands. Nothing changes. |
| Preview | The same fix as a dry run. Nothing is deleted or written. |
| Apply | The commands that change the machine. |
| Verify | How to confirm the fix worked. |
| Roll back | Only what the scripts really support, and a plain statement when a step cannot be undone. |
| Related | Links to the platform page and the scripts involved. |

Output shown on these pages is labelled as illustrative where it appears.
Your machine will print different numbers.

## Runbooks

| Runbook | Platform | When to use |
| --- | --- | --- |
| [A Linux host is low on disk space](linux-low-disk.md) | Linux | The root filesystem is nearly full and you need space now. |
| [Kubernetes pods are unhealthy](kubernetes-unhealthy-pods.md) | Kubernetes | Pods crash, stay Pending, or the cluster looks unhappy. |
| [A TLS certificate is expired or about to expire](tls-certificate-expiring.md) | Linux | A certificate has expired, a monitor says it is close, or clients report certificate errors. |
| [git push fails with Permission denied (publickey)](git-permission-denied-publickey.md) | Git | SSH refuses your key although it exists, or a `Host` block seems ignored. |
| [A Linux host cannot reach the network or resolve names](linux-network-unreachable.md) | Linux | Nothing is reachable, names do not resolve, or a service cannot be reached from outside. |

New runbooks are added one at a time. See
[Development](../contributing/development.md) for the page patterns they use.
