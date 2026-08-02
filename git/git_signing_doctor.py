#!/usr/bin/env python3
"""Diagnose why commit signing fails, and say how to fix it.

`error: gpg failed to sign the data` is the same unhelpful message whether the
key is missing, expired, configured for the wrong backend, or simply unable to
prompt for its passphrase because there is no terminal attached. And a commit
that signs perfectly well can still show up as "Unverified" on the forge, for
reasons that never produce an error locally at all.

The sibling script git_ssh_doctor.py diagnoses *transport* auth — getting a push
past `Permission denied (publickey)`. This one diagnoses *signing*, which is a
separate mechanism with separate failure modes, and which now has three possible
backends: openpgp, ssh, and x509. It is deliberately not named for gpg, because
the ssh backend is the one most people are adopting and nobody with
`gpg.format=ssh` would think to run a script called gpg-something.

Read-only. It prints commands to run; it never edits config, touches the agent,
or creates a key.

    ./git_signing_doctor.py              # diagnose signing in the current repo
    ./git_signing_doctor.py --test-sign  # also attempt one real signature
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tempfile
import time

HOME = os.path.expanduser("~")

C_RESET = C_RED = C_GREEN = C_YELLOW = C_DIM = C_BOLD = ""
if sys.stdout.isatty() and not os.environ.get("NO_COLOR"):
    C_RESET, C_BOLD, C_DIM = "\033[0m", "\033[1m", "\033[2m"
    C_RED, C_GREEN, C_YELLOW = "\033[31m", "\033[32m", "\033[33m"


def ok(msg):
    print("%s[ ok ]%s %s" % (C_GREEN, C_RESET, msg))


def warn(msg):
    print("%s[warn]%s %s" % (C_YELLOW, C_RESET, msg))


def bad(msg):
    print("%s[fail]%s %s" % (C_RED, C_RESET, msg))


def info(msg):
    print("%s[info]%s %s" % (C_DIM, C_RESET, msg))


def head(msg):
    print("\n%s== %s ==%s" % (C_BOLD, msg, C_RESET))


def shorten(path):
    return path.replace(HOME, "~", 1) if path.startswith(HOME) else path


def run(cmd, timeout=15, stdin_text=None):
    """Run a command, returning (rc, stdout, stderr). Never raises."""
    try:
        p = subprocess.run(
            cmd,
            capture_output=True,
            timeout=timeout,
            input=stdin_text.encode() if stdin_text is not None else None,
        )
        return (
            p.returncode,
            p.stdout.decode("utf-8", "replace"),
            p.stderr.decode("utf-8", "replace"),
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 255, "", str(exc)


# --------------------------------------------------------------------------
# Pure helpers. Everything below this line takes its input as a string or a
# path and returns data, so it can be unit-tested without a keyring, an agent,
# or a repository. That split is deliberate: the parts that shell out are left
# untested, because mocking them would only assert that the mock was called.
# --------------------------------------------------------------------------


def parse_git_config(text):
    """Parse `git config --list --show-origin --show-scope -z` output.

    Returns {key: [(value, origin, scope), ...]} in file order, so the *last*
    entry for a key is the effective one. Knowing which file a value came from
    is the point: a repo-local override silently beating your global config is
    a common and genuinely confusing failure.
    """
    entries = {}
    if not text:
        return entries

    tokens = text.split("\0")
    # Records are scope NUL origin NUL "key\nvalue". A trailing empty token is
    # normal because the final record is NUL-terminated too.
    i = 0
    while i + 2 < len(tokens) + 1:
        chunk = tokens[i : i + 3]
        if len(chunk) < 3:
            break
        scope, origin, keyval = chunk
        if not keyval:
            break
        if "\n" in keyval:
            key, value = keyval.split("\n", 1)
        else:
            key, value = keyval, ""
        entries.setdefault(key.lower(), []).append((value, origin, scope))
        i += 3
    return entries


def effective(entries, key):
    """The winning (value, origin, scope) for a key, or None."""
    values = entries.get(key.lower())
    return values[-1] if values else None


def parse_gpg_colons(text):
    """Parse `gpg --list-secret-keys --with-colons` into key records.

    Fields are documented in gnupg's doc/DETAILS. The ones that matter here:
    2 = validity ('e' expired, 'r' revoked, 'i' invalid), 5 = key id,
    7 = expiry as a unix timestamp, and for uid records 10 = the user id.
    """
    keys = []
    current = None
    for line in (text or "").splitlines():
        fields = line.split(":")
        if not fields:
            continue
        rectype = fields[0]

        if rectype == "sec":
            current = {
                "validity": fields[1] if len(fields) > 1 else "",
                "keyid": fields[4] if len(fields) > 4 else "",
                "expires": fields[6] if len(fields) > 6 else "",
                "fingerprint": "",
                "uids": [],
            }
            keys.append(current)
        elif rectype == "fpr" and current is not None and not current["fingerprint"]:
            if len(fields) > 9:
                current["fingerprint"] = fields[9]
        elif rectype == "uid" and current is not None:
            if len(fields) > 9 and fields[9]:
                current["uids"].append(fields[9])
    return keys


_EMAIL = re.compile(r"<([^>]+)>")


def uid_emails(record):
    """Email addresses from a key record's user ids, lowercased."""
    found = []
    for uid in record.get("uids", []):
        for match in _EMAIL.findall(uid):
            found.append(match.strip().lower())
    return found


def expiry_state(record, now):
    """Classify a key record as 'revoked', 'expired', 'expiring', or 'valid'.

    `now` is injected rather than read from the clock so the tests do not start
    failing on whatever day a fixture key would have expired.
    """
    validity = (record.get("validity") or "").lower()
    if "r" in validity:
        return "revoked"
    if "i" in validity:
        return "invalid"

    raw = record.get("expires") or ""
    if not raw:
        return "expired" if "e" in validity else "valid"
    try:
        expires = int(raw)
    except ValueError:
        return "expired" if "e" in validity else "valid"

    if expires <= now:
        return "expired"
    if expires - now < 30 * 24 * 3600:
        return "expiring"
    return "valid"


_HEX_KEYID = re.compile(r"^(0x)?[0-9A-Fa-f]{8,40}$")


def classify_signing_key(fmt, signingkey):
    """Work out what kind of thing user.signingkey names, and whether it fits.

    Returns (kind, problem). kind is one of 'gpg-keyid', 'ssh-path',
    'ssh-literal' or 'unknown'; problem is None or a human explanation. The
    mismatch this catches — a GPG key id left in place after switching
    gpg.format to ssh, or the reverse — produces an error message that names
    neither the format nor the key.
    """
    fmt = (fmt or "openpgp").strip().lower()
    value = (signingkey or "").strip()

    if not value:
        if fmt == "openpgp":
            return "unknown", (
                "user.signingkey is unset; git will guess from user.email and "
                "fail opaquely if no secret key matches"
            )
        return "unknown", "user.signingkey is unset, which the %s format requires" % fmt

    if value.startswith("ssh-") or value.startswith("ecdsa-sha2-"):
        kind = "ssh-literal"
    elif _HEX_KEYID.match(value):
        kind = "gpg-keyid"
    else:
        kind = "ssh-path"

    if fmt == "ssh" and kind == "gpg-keyid":
        return kind, (
            "gpg.format is ssh but user.signingkey looks like a GPG key id; "
            "the ssh backend wants a path to a key or a literal public key"
        )
    if fmt == "openpgp" and kind in ("ssh-path", "ssh-literal"):
        return kind, (
            "gpg.format is openpgp (the default) but user.signingkey looks like "
            "an SSH key; set gpg.format to ssh, or use a GPG key id"
        )
    return kind, None


def parse_allowed_signers(text):
    """Parse an allowed_signers file into (principals, keytype, key) tuples.

    Format is `principal[,principal...] [options] keytype base64`. Getting this
    wrong does not break signing at all — it breaks *verification*, so
    `git log --show-signature` reports "No principal matched" while every commit
    signs happily. The two failures are unrelated and are reported separately.
    """
    rows = []
    for line in (text or "").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 3:
            continue
        principals = [p.strip().lower() for p in parts[0].split(",") if p.strip()]
        keytype = ""
        blob = ""
        for i, token in enumerate(parts[1:], start=1):
            if token.startswith("ssh-") or token.startswith("ecdsa-sha2-"):
                keytype = token
                if len(parts) > i + 1:
                    blob = parts[i + 1]
                break
        if not keytype:
            continue
        rows.append((principals, keytype, blob))
    return rows


def find_program(name, path_env):
    """Resolve a program against an injected PATH string, or None.

    Takes PATH as a parameter so the "gpg.program points at something that is
    not there" check is testable without mutating the environment.
    """
    if not name:
        return None
    if os.path.sep in name:
        return name if os.path.isfile(name) and os.access(name, os.X_OK) else None
    for directory in (path_env or "").split(os.pathsep):
        if not directory:
            continue
        candidate = os.path.join(directory, name)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


# --------------------------------------------------------------------------
# Diagnostics
# --------------------------------------------------------------------------


def read_config():
    rc, out, _ = run(["git", "config", "--list", "--show-origin", "--show-scope", "-z"])
    if rc != 0:
        return None
    return parse_git_config(out)


def report_config(entries):
    head("configuration")
    interesting = [
        "commit.gpgsign",
        "tag.gpgsign",
        "gpg.format",
        "user.signingkey",
        "user.email",
        "gpg.program",
        "gpg.ssh.allowedsignersfile",
    ]
    for key in interesting:
        hit = effective(entries, key)
        if hit is None:
            continue
        value, origin, scope = hit
        origin = shorten(origin.replace("file:", ""))
        print("        %-28s %s  %s(%s, %s)%s" % (key, value, C_DIM, scope, origin, C_RESET))

        # A repo-local override beating a global one is invisible until you
        # notice signing behaves differently in one checkout.
        occurrences = entries.get(key, [])
        if len(occurrences) > 1:
            info("%s is set in %d places; the one above wins" % (key, len(occurrences)))


def diagnose(entries, now, path_env):
    """The checks that need no subprocess beyond what has already run."""
    problems = 0

    sign_commits = (effective(entries, "commit.gpgsign") or ("", "", ""))[0]
    fmt = (effective(entries, "gpg.format") or ("openpgp", "", ""))[0]
    signingkey = (effective(entries, "user.signingkey") or ("", "", ""))[0]
    email = (effective(entries, "user.email") or ("", "", ""))[0]

    head("signing key")
    if sign_commits.lower() not in ("true", "1", "yes"):
        info("commit.gpgsign is not enabled; signing only happens with `git commit -S`")

    kind, problem = classify_signing_key(fmt, signingkey)
    if problem:
        bad(problem)
        problems += 1
    else:
        ok("gpg.format=%s with a %s" % (fmt or "openpgp", kind))

    if kind == "ssh-path":
        expanded = os.path.expanduser(signingkey)
        if not os.path.exists(expanded):
            bad("user.signingkey points at %s, which does not exist" % shorten(expanded))
            problems += 1
        elif expanded.endswith(".pub"):
            info("signing with a public key path is correct for the ssh backend; "
                 "the private half must sit beside it")
        elif os.path.exists(expanded + ".pub"):
            info("fix: point user.signingkey at %s.pub" % shorten(expanded))

    program_key = "gpg.program" if (fmt or "openpgp") == "openpgp" else "gpg.ssh.program"
    program = (effective(entries, program_key) or ("", "", ""))[0]
    if program and not find_program(program, path_env):
        bad("%s is set to %r, which is not an executable on PATH" % (program_key, program))
        problems += 1

    return problems, fmt, signingkey, email


def diagnose_openpgp(entries, email, now):
    problems = 0
    head("gpg keyring")

    rc, out, err = run(["gpg", "--list-secret-keys", "--with-colons"])
    if rc == 255:
        bad("gpg is not installed or not on PATH (%s)" % err.strip())
        return problems + 1
    if rc != 0:
        bad("gpg --list-secret-keys failed: %s" % (err.strip() or rc))
        return problems + 1

    records = parse_gpg_colons(out)
    if not records:
        bad("no secret keys in the keyring — git cannot sign with a public key alone")
        info("fix: gpg --full-generate-key, or import your backup")
        return problems + 1

    ok("%d secret key(s) in the keyring" % len(records))

    usable = 0
    for record in records:
        state = expiry_state(record, now)
        label = record["fingerprint"] or record["keyid"]
        if state == "revoked":
            bad("%s is revoked" % label)
            problems += 1
        elif state == "expired":
            bad("%s has expired — this is the most common cause of a sudden "
                "'gpg failed to sign the data'" % label)
            info("fix: gpg --quick-set-expire %s 1y" % label)
            problems += 1
        elif state == "invalid":
            bad("%s is marked invalid" % label)
            problems += 1
        else:
            usable += 1
            if state == "expiring":
                warn("%s expires within 30 days" % label)

        if email:
            emails = uid_emails(record)
            if emails and email.lower() not in emails:
                warn("%s has no user id matching user.email (%s)" % (label, email))
                info("the forge matches the signature to an account by that address; "
                     "a mismatch is why a signed commit still shows as Unverified")

    if usable == 0:
        problems += 1

    # A passphrase-protected key cannot prompt without a terminal, and that is
    # exactly what the opaque failure looks like inside an editor or a hook.
    if not os.environ.get("GPG_TTY") and not sys.stdin.isatty():
        warn("GPG_TTY is unset and stdin is not a terminal; pinentry cannot prompt")
        info("fix: export GPG_TTY=$(tty)   # in your shell profile")

    return problems


def diagnose_ssh(entries, email):
    problems = 0
    head("ssh signing")

    # Presence is checked by resolving the binary, not by its exit code:
    # OpenSSH exits 255 on a usage error, which is also run()'s sentinel for
    # "could not execute", so the two are indistinguishable from rc alone.
    if not find_program("ssh-keygen", os.environ.get("PATH", "")):
        bad("ssh-keygen is not installed or not on PATH")
        return problems + 1
    rc, out, err = run(["ssh-keygen", "-Y", "sign", "-h"])
    combined = (out + err).lower()
    if "unknown option" in combined or "usage" not in combined and rc == 255:
        bad("this ssh-keygen is too old for `-Y sign` (OpenSSH 8.2+ is needed)")
        problems += 1
    else:
        ok("ssh-keygen supports -Y sign")

    hit = effective(entries, "gpg.ssh.allowedsignersfile")
    if hit is None:
        warn("gpg.ssh.allowedSignersFile is unset")
        info("signing still works; verification does not — `git log --show-signature` "
             "will report every commit as having no principal")
        info("fix: printf '%s namespaces=\"git\" <your key>\\n' > ~/.config/git/allowed_signers "
             "&& git config --global gpg.ssh.allowedSignersFile ~/.config/git/allowed_signers"
             % (email or "you@example.com"))
        return problems

    path = os.path.expanduser(hit[0])
    if not os.path.isfile(path):
        bad("gpg.ssh.allowedSignersFile points at %s, which does not exist" % shorten(path))
        return problems + 1

    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            rows = parse_allowed_signers(handle.read())
    except OSError as exc:
        bad("cannot read %s (%s)" % (shorten(path), exc))
        return problems + 1

    if not rows:
        bad("%s has no usable entries" % shorten(path))
        return problems + 1

    ok("%s lists %d principal set(s)" % (shorten(path), len(rows)))
    if email:
        listed = [p for row in rows for p in row[0]]
        if email.lower() not in listed:
            warn("your own address (%s) is not in the allowed signers file" % email)
            info("your commits will verify for others but not for you")
    return problems


def test_sign(fmt, signingkey):
    """Attempt one real signature. Opt-in, read-only, writes only to a temp dir."""
    head("test signature")
    fmt = (fmt or "openpgp").lower()

    if fmt == "ssh":
        if not signingkey:
            bad("cannot test: user.signingkey is unset")
            return 1
        key = os.path.expanduser(signingkey)
        with tempfile.TemporaryDirectory() as tmp:
            payload = os.path.join(tmp, "payload")
            with open(payload, "w", encoding="utf-8") as handle:
                handle.write("git_signing_doctor\n")
            rc, _, err = run(["ssh-keygen", "-Y", "sign", "-f", key, "-n", "git", payload])
        if rc == 0:
            ok("ssh-keygen produced a signature")
            return 0
        bad("ssh signing failed: %s" % (err.strip() or rc))
        return 1

    cmd = ["gpg", "--clearsign", "--batch", "--pinentry-mode", "error"]
    if signingkey:
        cmd += ["--local-user", signingkey]
    # --batch with pinentry-mode=error is not optional: without it a
    # passphrase-protected key waits forever for a prompt that cannot appear.
    rc, _, err = run(cmd, stdin_text="git_signing_doctor\n")
    if rc == 0:
        ok("gpg produced a signature")
        return 0
    bad("gpg signing failed: %s" % (err.strip().splitlines()[-1] if err.strip() else rc))
    if "no secret key" in err.lower():
        info("the configured key is not in this keyring")
    if "pinentry" in err.lower() or "passphrase" in err.lower():
        info("the key needs a passphrase and no pinentry was reachable; "
             "run once in a terminal, or export GPG_TTY=$(tty)")
    return 1


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Diagnose commit-signing failures (gpg, ssh and x509 backends)."
    )
    parser.add_argument("--test-sign", action="store_true",
                        help="attempt one real signature and report the raw error")
    parser.add_argument("--now", type=int, default=None, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)

    now = args.now if args.now is not None else int(time.time())

    entries = read_config()
    if entries is None:
        bad("git config failed — is git installed and is this a repository?")
        return 2

    report_config(entries)
    problems, fmt, signingkey, email = diagnose(entries, now, os.environ.get("PATH", ""))

    fmt_normalised = (fmt or "openpgp").lower()
    if fmt_normalised == "ssh":
        problems += diagnose_ssh(entries, email)
    elif fmt_normalised == "x509":
        head("x509")
        info("x509 signing is delegated to gpgsm; this script does not inspect it")
    else:
        problems += diagnose_openpgp(entries, email, now)

    if args.test_sign:
        problems += test_sign(fmt, signingkey)

    print()
    if problems:
        bad("%d problem(s) found" % problems)
        return 1
    ok("no signing problems found")
    return 0


if __name__ == "__main__":
    sys.exit(main())
