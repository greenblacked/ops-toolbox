#!/usr/bin/env bash
# packages.sh holds and orphans against stubbed package tools, driven through
# each package manager by OS_RELEASE fixtures, so any one image covers all three.
set -uo pipefail

# OS_RELEASE picks the package manager; each case below passes its own.
unset OS_RELEASE

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
PKGS="$REPO_ROOT/linux/packages.sh"
fixture="$(mktemp -d)" || exit 1
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin" || exit 1
STUB_DIR="$fixture"
export STUB_DIR
checks=0
failures=0
assert_eq() {
  checks=$((checks + 1))
  if [[ "$2" == "$3" ]]; then
    printf '[ ok ] %s\n' "$1"
  else
    printf '[fail] %s (expected %s, got %s)\n' "$1" "$2" "$3" >&2
    failures=$((failures + 1))
  fi
}
assert_contains() {
  checks=$((checks + 1))
  if [[ "$2" == *"$3"* ]]; then
    printf '[ ok ] %s\n' "$1"
  else
    printf '[fail] %s (missing %s)\n' "$1" "$3" >&2
    printf '%s\n' "$2" | head -20 >&2
    failures=$((failures + 1))
  fi
}

# Every tool answers from a fixture file, so a case changes its answer by
# rewriting the file. `apt`, `dnf` and `pacman` must exist because the script
# checks the detected manager is on PATH before anything else.
cat > "$fixture/bin/apt" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat > "$fixture/bin/apt-mark" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == showhold ]] && cat "$STUB_DIR/apt-mark.out"
exit "${APT_MARK_RC:-0}"
STUB
cat > "$fixture/bin/apt-get" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == "-s autoremove" ]]; then
  cat "$STUB_DIR/apt-get.out"
  exit "${APT_GET_RC:-0}"
fi
printf 'unexpected apt-get call: %s\n' "$*" >> "$STUB_DIR/unexpected"
exit 1
STUB
cat > "$fixture/bin/dnf" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  versionlock)
    if [[ -f "$STUB_DIR/versionlock.out" ]]; then
      cat "$STUB_DIR/versionlock.out"
      exit 0
    fi
    printf 'No such command: versionlock.\n' >&2
    exit 2
    ;;
  repoquery)
    cat "$STUB_DIR/dnf-unneeded.out"
    exit "${DNF_RC:-0}"
    ;;
esac
printf 'unexpected dnf call: %s\n' "$*" >> "$STUB_DIR/unexpected"
exit 1
STUB
cat > "$fixture/bin/pacman" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == "-Qdtq" ]]; then
  cat "$STUB_DIR/pacman.out"
  exit "${PACMAN_RC:-1}"
fi
printf 'unexpected pacman call: %s\n' "$*" >> "$STUB_DIR/unexpected"
exit 1
STUB
chmod +x "$fixture/bin/"*

printf 'nginx\nlinux-image-amd64\n' > "$fixture/apt-mark.out"
printf 'NOTE: This is only a simulation!\nRemv libold1 [1.0]\nInst x\n' > "$fixture/apt-get.out"
printf 'libfoo\nlibbar\n' > "$fixture/dnf-unneeded.out"
: > "$fixture/pacman.out"
printf 'ID=debian\n' > "$fixture/os-debian"
printf 'ID=fedora\n' > "$fixture/os-fedora"
printf 'ID=arch\n' > "$fixture/os-arch"

# run_pk OS ARGS... — stdout alone in $out, stderr alone in $errout.
run_pk() {
  local os="$1"; shift
  out="$(OS_RELEASE="$fixture/os-$os" PATH="$fixture/bin:$PATH" "$PKGS" "$@" 2>"$fixture/stderr")"
  rc=$?
  errout="$(cat "$fixture/stderr")"
}

out="$("$PKGS" --help 2>&1)"
assert_contains '--help lists holds' "$out" 'holds'
assert_contains '--help lists orphans' "$out" 'orphans'

run_pk debian holds
assert_eq 'apt holds exits 0' 0 "$rc"
assert_eq 'apt holds prints exactly the held names, sorted' "$(printf 'linux-image-amd64\nnginx')" "$out"
first="$out"
run_pk debian holds
assert_eq 'apt holds is stable across runs' "$first" "$out"
run_pk debian holds --dry-run
assert_eq 'holds accepts and ignores --dry-run' 0 "$rc"

run_pk debian orphans
assert_eq 'apt orphans exits 0' 0 "$rc"
assert_eq 'apt orphans prints only what autoremove would remove' 'libold1' "$out"
APT_GET_RC=100 run_pk debian orphans
assert_eq 'a failing apt-get -> 1' 1 "$rc"
assert_eq 'a failure prints nothing on stdout' '' "$out"

run_pk fedora orphans
assert_eq 'dnf orphans exits 0' 0 "$rc"
assert_eq 'dnf orphans prints the unneeded names, sorted' "$(printf 'libbar\nlibfoo')" "$out"
DNF_RC=1 run_pk fedora orphans
assert_eq 'a failing dnf repoquery -> 1' 1 "$rc"

# Without the versionlock plugin there is nothing to read: a note on stderr,
# never on stdout. The host's own dnf.conf can still list excludes, and those
# would rightly appear, so the empty-stdout check needs a dnf.conf without one.
run_pk fedora holds
assert_eq 'dnf holds without versionlock exits 0' 0 "$rc"
assert_contains 'the missing plugin is a note on stderr' "$errout" 'versionlock is not available'
if grep -qE '^[[:space:]]*(exclude|excludepkgs)[[:space:]]*=' /etc/dnf/dnf.conf 2>/dev/null; then
  assert_eq 'this host lists dnf excludes; stdout emptiness not checked' 1 1
else
  assert_eq 'dnf holds without versionlock prints nothing on stdout' '' "$out"
fi
printf '%s\n' '# Added by versionlock' 'nginx-0:1.24.0-1.fc41.*' '!badpkg-0:1.0-1.*' \
  'Package name: curl' 'evr = 8.9.1-2.fc41' > "$fixture/versionlock.out"
run_pk fedora holds
assert_eq 'dnf holds with versionlock exits 0' 0 "$rc"
assert_contains 'a dnf 4 lock is named' "$out" 'nginx'
assert_contains 'a dnf 5 lock is named' "$out" 'curl'
assert_eq 'an excluded version is not a hold' '' "$(grep -x badpkg <<<"$out")"
rm -f "$fixture/versionlock.out"

run_pk arch orphans
assert_eq 'pacman orphans with none (exit 1, no output) exits 0' 0 "$rc"
assert_eq 'pacman orphans with none prints nothing' '' "$out"
PACMAN_RC=0 run_pk arch orphans
assert_eq 'pacman orphans exits 0 when it lists none' 0 "$rc"
printf 'orphan-a\n' > "$fixture/pacman.out"
PACMAN_RC=0 run_pk arch orphans
assert_eq 'pacman orphans prints what -Qdtq lists' 'orphan-a' "$out"
: > "$fixture/pacman.out"
PACMAN_RC=2 run_pk arch orphans
assert_eq 'a failing pacman -> 1' 1 "$rc"

# IgnorePkg is read from /etc/pacman.conf, the path pacman itself uses, so
# only the empty answer can be asserted unless this host ignores something.
run_pk arch holds
assert_eq 'pacman holds exits 0' 0 "$rc"
if grep -qE '^[[:space:]]*IgnorePkg[[:space:]]*=[[:space:]]*[^[:space:]#]' /etc/pacman.conf 2>/dev/null; then
  assert_eq 'this host ignores packages; stdout emptiness not checked' 1 1
else
  assert_eq 'pacman holds with no IgnorePkg prints nothing' '' "$out"
fi

run_pk debian holds orphans
assert_eq 'two commands at once -> 3' 3 "$rc"
assert_contains 'two commands say why' "$errout" 'only one command'
run_pk debian holds extra
assert_eq 'holds with a stray word -> 3' 3 "$rc"
run_pk debian orphans --bogus
assert_eq 'orphans --bogus -> 3' 3 "$rc"

# Every fixture reaches an answer. Counted, because a loop that matched
# nothing would leave the checks above unchanged.
distros_run=0
for os in debian fedora arch; do
  distros_run=$((distros_run + 1))
  run_pk "$os" holds
  assert_eq "$os holds exits 0" 0 "$rc"
  run_pk "$os" orphans
  assert_eq "$os orphans exits 0" 0 "$rc"
done
assert_eq 'three distro fixtures exercised' 3 "$distros_run"
assert_eq 'no stub saw a call it does not expect' '' "$(cat "$fixture/unexpected" 2>/dev/null)"

if (( checks == 0 || failures > 0 )); then
  printf '%s of %s holds and orphans checks failed\n' "$failures" "$checks" >&2
  exit 1
fi
printf '=== all %s holds and orphans checks passed ===\n' "$checks"
