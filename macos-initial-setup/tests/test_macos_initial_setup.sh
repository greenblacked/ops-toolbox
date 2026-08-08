#!/usr/bin/env bash
# Run from the Linux tester container; repo root is mounted at /repo.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-/repo}"
M="$REPO_ROOT/macos-initial-setup"

if [[ ! -d "$M" ]]; then
  echo "expected macos-initial-setup at $M" >&2
  exit 1
fi

failures=0
ok()  { echo "[ ok ] $*"; }
err() { echo "[fail] $*" >&2; failures=$((failures + 1)); }

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    ok "$label"
  else
    err "$label (expected '$expected', got '$actual')"
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    ok "$label"
  else
    err "$label (missing '$needle')"
    printf '%s\n' "$haystack" | head -20 >&2
  fi
}

# --- discovery -------------------------------------------------------------
# Discovered rather than listed. The hardcoded array this replaced named four
# scripts and the package has grown to nine, so brewfile.sh, macos_defaults.sh,
# workstation_doctor.sh and launchd/stay_fresh_agent.sh had no coverage here at
# all — for long enough that the omission is quoted as the cautionary tale in
# git/tests and test-env/lib/discover_clis.sh.
#
# Depth 2 so launchd/ is included; tests/ is the one subdirectory left out,
# because this file lives in it. zsh_aliases.zsh is not in the glob and is
# handled separately below: it is sourced, not run, so the --help and
# unknown-flag contracts do not apply to it. Built without mapfile to stay
# Bash 3.2-clean (see CONTRIBUTING.md).
sh_scripts=()
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  sh_scripts+=("$f")
done < <(find "$M" -maxdepth 2 -name '*.sh' -type f ! -path "$M/tests/*" | sort)

if (( ${#sh_scripts[@]} == 0 )); then
  echo "discovered no scripts under $M — discovery is broken" >&2
  exit 1
fi
ok "discovered ${#sh_scripts[@]} scripts under macos-initial-setup/"

# --- bash -n (syntax) ---
for f in "${sh_scripts[@]}"; do
  if bash -n "$f"; then
    ok "bash -n ${f#"$REPO_ROOT/"}"
  else
    err "bash -n ${f#"$REPO_ROOT/"}"
  fi
done

# --- shellcheck (errors only; warnings are too noisy for legacy/v1 script style) ---
for f in "${sh_scripts[@]}"; do
  rel="${f#"$REPO_ROOT/"}"
  if shellcheck --severity=error -x -s bash "$f"; then
    ok "shellcheck (bash) $rel"
  else
    err "shellcheck (bash) $rel"
  fi
done

zsh_file="$M/zsh_aliases.zsh"
if [[ -f "$zsh_file" ]]; then
  set +e
  sc_err="$(shellcheck --severity=error -s zsh "$zsh_file" 2>&1)"
  sc_rc=$?
  set -e
  if [[ "$sc_rc" -eq 0 ]]; then
    ok "shellcheck (zsh) ${zsh_file#"$REPO_ROOT/"}"
  elif grep -q "Unknown shell" <<<"$sc_err"; then
    ok "shellcheck (zsh) skipped (no zsh in this shellcheck build)"
  else
    echo "$sc_err" >&2
    err "shellcheck (zsh) ${zsh_file#"$REPO_ROOT/"}"
  fi
else
  err "missing $zsh_file"
fi

# --- --help (must work before macOS preflight) ---
for f in "${sh_scripts[@]}"; do
  if "$f" --help >/dev/null 2>&1; then
    ok "${f#"$M/"} --help"
  else
    err "${f#"$M/"} --help"
  fi
done

# --- unknown CLI -> exit 3 (parsed before preflight) ---
for f in "${sh_scripts[@]}"; do
  set +e
  out="$("$f" --definitely-not-a-valid-flag-12345 2>&1)"; rc=$?
  set -e
  if [[ "$rc" -eq 3 ]]; then
    ok "${f#"$M/"} unknown flag -> exit 3"
  else
    err "${f#"$M/"} unknown flag: expected exit 3, got $rc: $(printf '%s' "$out" | head -3)"
  fi
done

# --- Linux / non-Darwin: preflight should reject (documented exit 2) ---
# Discovery again, with a table for the two scripts that need an argument to
# reach their preflight at all. Naming exceptions rather than subjects is what
# keeps this from rotting the way the old list did: a new script is covered the
# day it lands, and only a script that genuinely differs has to be touched.
preflight_args() {
  case "${1##*/}" in
    brewfile.sh)         printf '%s\n' "check" ;;
    stay_fresh_agent.sh) printf '%s\n' "status" ;;
    *)                   printf '%s\n' "" ;;
  esac
}

if [[ "$(uname -s)" == "Linux" ]]; then
  for f in "${sh_scripts[@]}"; do
    name="${f##*/}"
    # v1_stay_fresh.sh has no platform guard by design: it is the preserved
    # original and its documented exit codes are 0, 1 (no usable home) and 2
    # (bad arguments), with no 'wrong OS' among them.
    if [[ "$name" == "v1_stay_fresh.sh" ]]; then
      ok "$name: skipped, it has no platform guard by design"
      continue
    fi
    set +e
    # shellcheck disable=SC2046  # an empty argument list must vanish, not become ''
    out="$("$f" $(preflight_args "$f") 2>&1)"; rc=$?
    set -e
    if [[ "$rc" -ne 2 ]]; then
      err "$name: expected exit 2 on Linux, got $rc"
    elif ! grep -q "macOS" <<<"$out"; then
      err "$name: expected 'macOS' in the output on Linux"
    else
      ok "$name: Linux preflight -> exit 2 (macOS only)"
    fi
  done
else
  ok "skipping Linux preflight assertions (unusual host OS: $(uname -s))"
fi

# --- hardening_audit: the group flags answer before preflight ---
# --list-groups and group validation are the two things this suite can check
# about the audit on Linux, and they are the two worth checking: both have to
# happen ahead of the macOS-only probes, exactly like --help does.
AUDIT="$M/hardening_audit.sh"
if [[ -x "$AUDIT" ]]; then
  set +e
  groups_out="$("$AUDIT" --list-groups 2>&1)"; rc=$?
  set -e
  assert_eq "hardening_audit --list-groups exits 0" "0" "$rc"
  for g in sharing firewall updates disk sip gatekeeper; do
    assert_contains "hardening_audit lists the $g group" "$groups_out" "$g"
  done

  set +e
  "$AUDIT" --only nosuchgroup >/dev/null 2>&1; rc=$?
  set -e
  assert_eq "hardening_audit rejects an unknown group -> 3" "3" "$rc"

  set +e
  "$AUDIT" --fail-on sometimes >/dev/null 2>&1; rc=$?
  set -e
  assert_eq "hardening_audit rejects a bad --fail-on -> 3" "3" "$rc"
else
  err "missing $AUDIT"
fi

# --- lib/: stay_fresh.sh hard-depends on the scanner at runtime ---
# The dependency is invoked by absolute path from a step that only runs on
# macOS, so nothing else in this suite would notice the file being renamed,
# moved or broken. Check it here.
scanner="$M/lib/workspace_scan.py"
if [[ -f "$scanner" ]]; then
  ok "lib/workspace_scan.py present"
  if command -v python3 >/dev/null 2>&1; then
    # Compile to an explicit cfile under /tmp. `python3 -m py_compile` writes a
    # __pycache__ next to the source, and the repo is mounted read-only here —
    # which fails with EROFS and looks exactly like a syntax error.
    if python3 -c 'import py_compile,sys; py_compile.compile(sys.argv[1], cfile="/tmp/ws_scan.pyc", doraise=True)' \
         "$scanner" 2>/dev/null; then
      ok "lib/workspace_scan.py compiles"
    else
      err "lib/workspace_scan.py does not compile"
      python3 -c 'import py_compile,sys; py_compile.compile(sys.argv[1], cfile="/tmp/ws_scan.pyc", doraise=True)' \
        "$scanner" 2>&1 | tail -3 >&2
    fi
    # stay_fresh.sh reads the NUL-delimited form; a change to the record shape
    # silently breaks the shell side, which cannot be seen from bash -n.
    scan_tmp="$(mktemp -d)"
    mkdir -p "$scan_tmp/ws/entry"
    printf '{"folder": "file://%s/gone"}' "$scan_tmp" >"$scan_tmp/ws/entry/workspace.json"
    if python3 "$scanner" "$scan_tmp/ws" --volumes-dir "$scan_tmp/vol" \
         | tr '\0' '\n' | grep -q "^stale	"; then
      ok "lib/workspace_scan.py emits NUL-delimited stale records"
    else
      err "lib/workspace_scan.py output shape changed"
    fi
    rm -rf "$scan_tmp"
  else
    ok "python3 absent in this image — skipped scanner compile check"
  fi
else
  err "missing $scanner (stay_fresh.sh invokes it at runtime)"
fi

# The step must name the interpreter absolutely: a bare `python3` picks up
# whichever pyenv shim or activated virtualenv is first on a developer's PATH.
if grep -q 'local py=/usr/bin/python3' "$M/stay_fresh.sh"; then
  ok "stay_fresh.sh pins /usr/bin/python3"
else
  err "stay_fresh.sh no longer pins an absolute interpreter path"
fi

# --- zsh_aliases: must source cleanly in zsh (Linux) ---
if zsh -f -c "source '$M/zsh_aliases.zsh'"; then
  ok "zsh: source zsh_aliases.zsh"
else
  err "zsh: source zsh_aliases.zsh"
fi

if (( failures )); then
  echo "=== $failures test(s) failed ===" >&2
  exit 1
fi
echo "=== all macos-initial-setup (docker) checks passed ==="
exit 0
