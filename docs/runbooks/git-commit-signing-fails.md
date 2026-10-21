# Commits fail to sign or show Unverified

<!-- markdownlint-disable MD033 -->

**When to use:** `git commit` fails because the commit cannot be signed, or
commits sign locally but the forge shows them as Unverified, and you need to
know which of the possible causes it is.

## Symptoms

- `error: gpg failed to sign the data` followed by
  `fatal: failed to write commit object`, the same message for an expired
  key, a missing pinentry or the wrong backend.
- Signing works in a terminal but fails or hangs inside an editor, a Git GUI,
  a hook or CI.
- Commits push fine but the forge marks them Unverified.
- `git log --show-signature` reports that no principal matched.

## Before you start

- A shell inside the repository. The doctor reads the effective Git
  configuration from there, so a repository-local setting that overrides
  your global one is seen.
- `python3` 3.9 or newer (standard library only) and `git`.
- `gpg` for OpenPGP signing, or `ssh-keygen` from OpenSSH 8.2 or newer for
  SSH signing. The doctor reports a missing or too old one.
- The script. Work from a clone of the repository, or copy
  `git/git_signing_doctor.py` onto the machine; it works on its own. See
  [Installation and usage](../getting-started/usage.md).
- More on the Git scripts is on the [Git page](../platforms/git.md).

Nothing on this page needs your private key, its passphrase or the contents
of your keyring. Do not paste them into a ticket or a chat.

## Report

<span class="stage stage-report">read-only</span>

!!! report "Nothing changes in this step"
    The doctor reads Git configuration and lists your keys. It never edits
    config, touches the agent or creates a key, and without `--test-sign` it
    signs nothing.

```{ .bash .rpt-report title="Report" }
./git/git_signing_doctor.py
```

It prints these sections:

1. **configuration**: `commit.gpgsign`, `tag.gpgsign`, `gpg.format`,
   `user.signingkey`, `user.email`, `gpg.program` and
   `gpg.ssh.allowedSignersFile`, each with the scope and file it came from,
   and a note when a key is set in more than one place.
2. **signing key**: whether `user.signingkey` fits `gpg.format`. A GPG key id
   with `gpg.format=ssh`, an SSH key with the default `openpgp` format, an
   unset key, or a key path that does not exist are failures. So is a
   `gpg.program` (or `gpg.ssh.program`) that is not an executable on `PATH`.
3. Then one section for the backend in use:
    - **gpg keyring** (`openpgp`, the default): no secret key at all; a key
      that is revoked, invalid or expired ("the most common cause of a sudden
      'gpg failed to sign the data'"); a key that expires within 30 days (these
      checks read the primary secret key, the `sec` record, only; see the note
      below the exit codes for signing subkeys); no
      user id matching `user.email`, which is why a signed commit still shows
      as Unverified; and `GPG_TTY is unset and stdin is not a terminal`, so
      pinentry cannot ask for the passphrase.
    - **ssh signing** (`gpg.format=ssh`): `ssh-keygen` missing or too old for
      `-Y sign`; `gpg.ssh.allowedSignersFile` unset, missing, unreadable or
      with no usable entries; your own address not in that file, so your
      commits verify for others but not for you.
    - **x509**: the doctor says it delegates to `gpgsm` and does not inspect
      it. It checks nothing for this backend beyond the configuration above.

`--quiet` prints nothing and keeps the exit code. It does not enable
`--test-sign`.

| Exit | Meaning |
| --- | --- |
| `0` | No problems found. |
| `1` | Problems found; the last line gives the count. |
| `2` | `git config` could not be read (no `git`). |
| `3` | Bad arguments. |

Exit `0` does not clear a signing subkey. The expiry and revocation checks
read only the primary key (`sec` records); the doctor does not parse `ssb`
subkey records. If you sign with a dedicated signing subkey, an expired or
revoked subkey is not diagnosed and the report can still exit `0`. Check it
with `--test-sign` (below), or by hand: `gpg -K --with-colons`, then read the
`ssb` lines for your signing subkey (field 2 is the validity, `e` expired or
`r` revoked; field 7 is the expiry as a unix timestamp).

Only `[fail]` lines count as problems. The `[warn]` findings (a key that
expires soon, a user id that does not match `user.email`, `GPG_TTY` unset,
an unset allowed-signers file, your address missing from it) leave the exit
code at `0`. For the Unverified case those warnings are usually the answer,
so read them.

## Preview

<span class="stage stage-report">read-only</span>

!!! preview "One real signature"
    `--test-sign` asks the configured backend for one real signature over a
    throwaway payload. It creates no commit and changes no config. With
    `gpg` it runs in batch mode and never prompts: a key whose passphrase is
    not cached fails instead. With `ssh-keygen` it may ask for the key's
    passphrase, and a hardware key may need a touch. Each command gets 15
    seconds.

    `--test-sign` covers `ssh` and OpenPGP only. For `gpg.format=x509` it
    falls through to `gpg --clearsign --local-user <x509 id>`, which does
    not exercise `gpgsm` and usually fails because `gpg` holds no such
    secret key. Neither a pass nor a fail there says anything about X.509
    signing. Check X.509 by hand (see Verify).

```{ .bash .rpt-preview title="Preview" }
./git/git_signing_doctor.py --test-sign
```

It ends the report with a `test signature` section:
`gpg produced a signature` or `ssh-keygen produced a signature`, or the
backend's own error line. For `gpg` it adds a hint when that error is about a missing secret key
or an unreachable pinentry.

## Apply

<span class="stage stage-apply">changes things</span>

!!! apply "You run the fix, the script does not"
    The doctor only prints commands. Record your signing configuration
    before you change it, so you can put it back.

```{ .bash .rpt-apply title="Record first" }
git config --show-origin --get-regexp '^(user|gpg|commit)\.'
```

That is plain `git`. Then run only the fix the report printed for your case:

| Finding | Fix the doctor prints |
| --- | --- |
| No secret key in the keyring | `gpg --full-generate-key`, or import your backup |
| The key has expired | `gpg --quick-set-expire KEY 1y` |
| `GPG_TTY` is unset | `export GPG_TTY=$(tty)` in your shell profile |
| An SSH private key path in `user.signingkey` | Point `user.signingkey` at the `.pub` beside it |
| `gpg.ssh.allowedSignersFile` is unset | A `printf` line that writes `~/.config/git/allowed_signers` with your address, and the `git config --global gpg.ssh.allowedSignersFile` that points at it |

The allowed-signers command writes the file with `>`, which replaces a file
that is already there. Check for one first and add your line to it instead.
It also fails if `~/.config/git` does not exist yet, so create the directory
before running it:

```{ .bash .rpt-apply title="Apply, only if the directory is missing" }
mkdir -p ~/.config/git
```

For the other failures the finding itself says what is wrong: a revoked or
invalid key needs a new key, a format mismatch needs `gpg.format` and
`user.signingkey` to agree, a missing program needs installing or the
`gpg.program` setting corrected, and an Unverified commit needs a user id
(or, for SSH, a key registered on the forge) that matches the address you
commit with.

## Verify

<span class="stage stage-report">read-only</span>

```{ .bash .rpt-report title="Verify" }
./git/git_signing_doctor.py --test-sign
```

Success is `no signing problems found`, exit `0`, a `produced a signature`
line, and none of the `[warn]` lines that applied to you. Then make your next
commit with signing on and check it with `git log --show-signature -1`
(plain `git`). For the Unverified case, push it and check that the forge
shows it as verified; that last check is outside the toolbox.

For `gpg.format=x509`, `--test-sign` does not test `gpgsm`. Make a real
signed commit on a scratch branch instead, then read it back (plain
`git`):

```bash
git switch -c scratch/sign-check
git commit --allow-empty -S -m "sign check"
git log --show-signature -1
```

Delete the scratch branch afterwards.

## Roll back

The doctor changed nothing. Undo only your own edits, using the
configuration you recorded before the Apply step: set each changed key back
with `git config`, or `git config --unset` a key you added (plain `git`).
A key expiry you extended stays extended; that is a change to the key, not
to Git.

## Related

- `git/git_ssh_doctor.py`: getting a push past
  `Permission denied (publickey)`. Transport authentication is a separate mechanism, even when
  the same SSH key is used for both.
- `git/git_remote_doctor.py`: the URL git actually dials and the credential
  helpers it uses. It exits `1` on problems, `2` when `git config` is
  unavailable, and `4` when there are no remotes and no `--url`.
- [Git platform page](../platforms/git.md)
- [`git/` folder README](https://github.com/greenblacked/ops-toolbox/blob/master/git/README.md)
- [Scripts overview](../scripts/index.md)

<!-- markdownlint-enable MD033 -->
