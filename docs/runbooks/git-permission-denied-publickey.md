# git push fails with Permission denied (publickey)

<!-- markdownlint-disable MD033 -->

**When to use:** `git push`, `pull` or `clone` over SSH fails with
`Permission denied (publickey)` although you have a key, or a `Host` block
you wrote in `~/.ssh/config` seems to be ignored.

## Symptoms

- `git@github.com: Permission denied (publickey).` followed by
  `fatal: Could not read from remote repository.`
- The same key works from another machine or another account.
- A `Host` block with an `IdentityFile` is in a file you `Include`, and ssh
  behaves as if it were not there.

## Before you start

- A shell inside the repository whose remote fails, or the host name of the
  remote (for example `github.com`).
- For `git/git_ssh_doctor.py`: `python3` 3.9 or newer (standard library
  only) and the OpenSSH client, because it asks `ssh -G` for the effective
  configuration. It runs on Linux and macOS. See the
  [Git page](../platforms/git.md).
- For `linux/ssh_client_doctor.sh`: a Linux machine with Bash 3.2 or newer.
  It is exit `2` anywhere else. See the [Linux page](../platforms/linux.md).
- The scripts. Work from a clone of the repository, or copy the two files
  onto the machine; each works on its own. See
  [Installation and usage](../getting-started/usage.md).

Never paste a private key into a terminal log, a ticket or a chat to get
help. Nothing on this page needs its contents.

## Report

<span class="stage stage-report">read-only except known_hosts</span>

!!! report "Nothing is edited except known_hosts"
    Neither script edits a config file, loads anything into the agent or
    writes a key. `git_ssh_doctor.py` does make one real, non-interactive
    connection per host (see below). One exception: it connects with
    `StrictHostKeyChecking=accept-new`, so a host that is not yet in
    `~/.ssh/known_hosts` has its key added there.

Start with the doctor that asks OpenSSH what it will really do:

```{ .bash .rpt-report title="Report" }
./git/git_ssh_doctor.py
./git/git_ssh_doctor.py --host github.com
```

Without `--host` it checks the SSH remotes of the repository you are in.
`--host` is repeatable. It prints these sections:

| Section | What it reports |
| --- | --- |
| `ssh config` | Every config file it loaded, following `Include`. An `Include` whose glob matches **only directories** is a `[fail]`: ssh does not descend into a directory and reports no error, so every file inside is silently ignored. The suggested fix is printed on the next line (`fix: Include PATTERN/*`). An `Include` that matches nothing is a `[warn]`. |
| `keys` | Every private key under `~/.ssh`, at any depth. A key that is group- or world-accessible is a `[fail]`: "ssh will refuse it (chmod 600)". |
| `host: NAME` | What `ssh -G` resolves the host to (`user@hostname:port`), which identity files it offers and whether they exist, and whether the agent holds any identity. When none of the offered files exist it says these are OpenSSH's built-in defaults and that no `Host` block matched. |
| `fix` | Printed only after `--test-auth` finds a key that works (see Preview). |

When the host has an existing configured key or the agent holds an identity,
the report then tries **one** non-interactive `ssh -T git@HOST` with what
ssh would offer and prints `authentication succeeds` or
`authentication fails`. That is a real connection attempt, even with
`--quiet`.

`--quiet` prints nothing and keeps the exit code. It does not enable
`--test-auth`.

| Exit | Meaning |
| --- | --- |
| `0` | Every checked host authenticates. |
| `1` | At least one host does not, or the repository has no SSH remote and you gave no `--host`. |
| `3` | Bad arguments. |

On Linux, check the client directory itself as well:

```{ .bash .rpt-report title="Report, Linux" }
./linux/ssh_client_doctor.sh
./linux/ssh_client_doctor.sh --fail-on warn
```

It looks at three things OpenSSH refuses with a message that names none of
them: the mode of `~/.ssh` (group and other bits must be clear, so `700`),
the mode of each private key (`600`), and `IdentityFile` lines in
`~/.ssh/config` whose path does not exist. It also flags `config`,
`authorized_keys` and `known_hosts` when group or other can write them.
`--ssh-dir DIR` checks another directory; `--quiet` prints only warnings
and failures, plus the section headings and the summary.

A missing `IdentityFile` is a `[warn]`, and the default `--fail-on fail`
exits `0` on warnings, so pass `--fail-on warn` when you want the exit code
to count it. Exit codes: `0` clean, `1` findings at or above `--fail-on`,
`2` preflight failed (not Linux, `$HOME` unset, or the path is not a
directory), `3` bad arguments. A
missing `~/.ssh` is a skip and exits `0`.

## Preview

<span class="stage stage-report">read-only except known_hosts</span>

!!! preview "This step makes real connection attempts"
    `--test-auth` tries every private key it found under `~/.ssh` against
    the host, one connection per key. It writes no key and loads nothing
    into the agent, but some hosts may rate-limit or block an address after
    repeated failed logins.

When the report says authentication fails, find out which of your keys the
host accepts:

```{ .bash .rpt-preview title="Preview" }
./git/git_ssh_doctor.py --host github.com --test-auth
```

Each key is tried alone (`IdentitiesOnly=yes`, `BatchMode=yes`), so no
passphrase prompt appears; a key that needs a passphrase may report as
failing for that reason. If one works, the `fix` section shows the
`Host` block to append to `~/.ssh/config` and an `ssh-add` command, and
ends with `Verify with  ssh -T git@HOST`. If none works it says so: the key
for this host may not be under `~/.ssh`, or is not registered with the
remote account.

Every connection the doctor makes passes
`StrictHostKeyChecking=accept-new`. That is OpenSSH behaviour, not a script
feature: the first connection to a host whose key you have never accepted
adds that key to `~/.ssh/known_hosts` without asking.

## Apply

<span class="stage stage-apply">changes things</span>

!!! apply "You run the fix, the scripts do not"
    Both scripts only print commands. Before you change any mode, record
    what is there now, so you can put it back.

```{ .bash .rpt-apply title="Record first" }
ls -la ~/.ssh
```

Then run only the fix the report printed for your case:

| Finding | Printed fix |
| --- | --- |
| `~/.ssh` mode is wrong | `chmod 700 ~/.ssh` |
| A private key's mode is wrong | `chmod 600 KEY` |
| `Include` matches only directories | Change the line to `Include PATTERN/*` |
| A working key is never offered | Append the printed `Host` block (`HostName`, `User git`, `IdentityFile`, `IdentitiesOnly yes`), or load the key into the agent |
| `IdentityFile` path does not exist | Point it at the key you have, or remove the line |

The agent command the doctor prints is `ssh-add --apple-use-keychain KEY`,
which is the macOS form. On Linux, the standard OpenSSH command is
`ssh-add KEY`.

## Verify

<span class="stage stage-report">read-only except known_hosts</span>

```{ .bash .rpt-report title="Verify" }
./git/git_ssh_doctor.py --host github.com
./linux/ssh_client_doctor.sh --fail-on warn
```

Success is `[ ok ] authentication succeeds` and exit `0` from the doctor,
and exit `0` from the client check. Once a host authenticates, `--test-auth`
adds nothing: the per-key test runs only after a failure. In automation,
`./git/git_ssh_doctor.py --quiet --host github.com` gives the same verdict as
an exit code alone; it still connects to the host.

Then run the `git push` that failed.

## Roll back

The scripts changed nothing. The only changes are the ones you made:

- Modes: restore them from the `ls -la` listing you recorded.
- `~/.ssh/config`: remove the lines you added, or restore your copy.
- The agent: `ssh-add -d KEY` removes an identity you added (standard
  OpenSSH).
- `~/.ssh/known_hosts`: a host key added on first contact stays there until
  you remove it, for example with `ssh-keygen -R HOST` (standard OpenSSH).

Not covered by these scripts: the server side. Whether the public key is
registered with your account, deploy-key scope (a deploy key is tied to one
repository), and forge or organisation settings that restrict SSH access are
checked on the forge, not here.

## Related

- `git/git_signing_doctor.py`: commit signing is a separate mechanism, even
  when it uses an SSH key.
- `git/git_remote_doctor.py`: the URL git actually dials, `insteadOf`
  rewrites and credential helpers, for a remote that goes somewhere
  unexpected or asks for a password.
- [Git platform page](../platforms/git.md)
- [`git/` folder README](https://github.com/greenblacked/ops-toolbox/blob/master/git/README.md)
- [Scripts overview](../scripts/index.md)

<!-- markdownlint-enable MD033 -->
