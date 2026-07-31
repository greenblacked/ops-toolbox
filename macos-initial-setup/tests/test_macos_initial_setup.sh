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

# --- bash -n (syntax) ---
sh_scripts=(
  "$M/install_apps.sh"
  "$M/install_devtools.sh"
  "$M/stay_fresh.sh"
  "$M/v1_stay_fresh.sh"
)
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
if "$M/install_apps.sh" --help >/dev/null; then ok "install_apps.sh --help"; else err "install_apps.sh --help"; fi
if "$M/install_devtools.sh" --help >/dev/null; then ok "install_devtools.sh --help"; else err "install_devtools.sh --help"; fi
if "$M/stay_fresh.sh" --help >/dev/null; then ok "stay_fresh.sh --help"; else err "stay_fresh.sh --help"; fi
if "$M/v1_stay_fresh.sh" --help >/dev/null; then ok "v1_stay_fresh.sh --help"; else err "v1_stay_fresh.sh --help"; fi

# --- unknown CLI -> exit 3 (parsed before preflight) ---
set +e
out_ia="$("$M/install_apps.sh" --definitely-not-a-valid-flag-12345 2>&1)"; rc_ia=$?
set -e
if [[ "$rc_ia" -eq 3 ]]; then
  ok "install_apps.sh unknown flag -> exit 3"
else
  err "install_apps.sh unknown flag: expected exit 3, got $rc_ia: $out_ia"
fi

# --- Linux / non-Darwin: preflight should reject (documented exit 2) ---
if [[ "$(uname -s)" == "Linux" ]]; then
  for script in install_apps.sh install_devtools.sh stay_fresh.sh; do
    set +e
    out="$("$M/$script" --dry-run 2>&1)"; rc=$?
    set -e
    if [[ "$rc" -ne 2 ]]; then
      err "$script: expected exit 2 on Linux, got $rc"
    elif ! grep -q "macOS" <<<"$out"; then
      err "$script: expected 'macOS' in stderr on Linux"
    else
      ok "$script: Linux preflight -> exit 2 (macOS only)"
    fi
  done
else
  ok "skipping Linux preflight assertions (unusual host OS: $(uname -s))"
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
