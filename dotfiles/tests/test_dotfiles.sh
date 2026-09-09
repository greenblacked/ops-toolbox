#!/usr/bin/env bash
# Contract and behaviour checks for dotfiles/.
#
# Two halves. The first runs install_dotfiles.sh against a scratch home and
# asserts what it promises: --help before preflight, exit 3 on a bad flag, a
# dry run that writes nothing, links that point at this folder, copies for the
# files their tools rewrite, conflicts left in place, --force moving them to a
# .backup, --status telling MATCH from DRIFT, and an uninstall that removes
# only what it made. The file table is read from `--list` rather than
# re-derived here, so the suite asserts what the installer says it will do.
# The second half reads the tracked configs themselves: every file parses in
# the format its tool expects (where a parser is available), none is
# executable, none carries a secret, and the README names every one of them.
set -uo pipefail

# -P: the installer resolves its own directory physically, and the link
# targets it writes are compared against paths derived from this one.
HERE="$(cd -P "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"
D="$REPO_ROOT/dotfiles"
SCRIPT="$D/install_dotfiles.sh"

failures=0
ok()   { printf '[ ok ] %s\n' "$*"; }
err()  { printf '[fail] %s\n' "$*" >&2; failures=$((failures + 1)); }
skip() { printf '[skip] %s\n' "$*"; }
head_() { printf '\n--- %s ---\n' "$*"; }

assert_rc() {
  local label="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then ok "$label"; else err "$label (expected exit $want, got $got)"; fi
}

# Same argument order as linux/tests/test_linux_scripts.sh and the macOS
# suite, so an assertion line copied between suites keeps its meaning.
assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    ok "$label"
  else
    err "$label (missing '$needle')"
    printf '%s\n' "$haystack" | head -20 >&2
  fi
}

assert_true() {
  local label="$1"; shift
  if "$@"; then ok "$label"; else err "$label"; fi
}

TIMEOUT_BIN="$(command -v timeout || true)"
if [[ -n "$TIMEOUT_BIN" ]]; then guard() { "$TIMEOUT_BIN" 20 "$@"; }; else guard() { "$@"; }; fi

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
H="$scratch/home"
T="$scratch/tmp"
mkdir -p "$H" "$T"

# Every installer run gets the scratch home and tmp, and no XDG_CONFIG_HOME:
# with --home the installer ignores it by design, and a test must never be
# able to reach the developer's real config directory whatever the shell
# exports.
run_installer() { HOME="$H" TMPDIR="$T" env -u XDG_CONFIG_HOME "$TIMEOUT_BIN" 20 "$SCRIPT" --home "$H" "$@"; }
[[ -n "$TIMEOUT_BIN" ]] || run_installer() { HOME="$H" TMPDIR="$T" env -u XDG_CONFIG_HOME "$SCRIPT" --home "$H" "$@"; }

# Names plus mtimes of both scratch directories, so a rewritten file is
# caught as well as a new one, and a log written to TMPDIR is caught too.
snapshot() { find "$1" "$2" -mindepth 1 -printf '%p %T@\n' 2>/dev/null | sort; }
# macOS find has no -printf; fall back to one batched ls there.
if ! find "$scratch" -maxdepth 0 -printf '' >/dev/null 2>&1; then
  snapshot() { find "$1" "$2" -mindepth 1 -exec ls -ld {} + 2>/dev/null | sort; }
fi

# --------------------------------------------------------------------------
head_ "CLI contract"
out="$(guard "$SCRIPT" --help 2>&1)"; rc=$?
assert_rc "--help exits 0" 0 "$rc"
assert_contains "--help documents --dry-run" "$out" "--dry-run"
assert_contains "--help documents the exit codes" "$out" "Exit codes:"

guard "$SCRIPT" --definitely-not-a-flag >/dev/null 2>&1; rc=$?
assert_rc "unknown flag exits 3" 3 "$rc"
guard "$SCRIPT" --only >/dev/null 2>&1; rc=$?
assert_rc "--only without a value exits 3" 3 "$rc"
run_installer --status --uninstall >/dev/null 2>&1; rc=$?
assert_rc "two modes at once exit 3" 3 "$rc"
guard "$SCRIPT" --home "$scratch/does-not-exist" >/dev/null 2>&1; rc=$?
assert_rc "a missing home directory exits 2" 2 "$rc"
run_installer --status --only no-such-unit >/dev/null 2>&1; rc=$?
assert_rc "an unknown --only unit exits 3" 3 "$rc"

# --------------------------------------------------------------------------
head_ "--list is the file table"
list="$(run_installer --list 2>&1)"; rc=$?
assert_rc "--list exits 0" 0 "$rc"
assert_contains "--list names the k9s unit" "$list" "k9s"
assert_contains "--list names the git unit" "$list" "git"

# UNIT MODE SOURCE TARGET rows, header dropped. Everything below is driven
# from these, so the test cannot drift from the installer's own mapping.
units=(); modes=(); sources=(); targets=()
while read -r u m s t; do
  [[ "$u" == "UNIT" ]] && continue
  units+=("$u"); modes+=("$m"); sources+=("$s"); targets+=("$t")
done <<< "$list"
n_rows=${#sources[@]}
if (( n_rows > 0 )); then ok "--list reports $n_rows files"; else err "--list reported no files"; exit 1; fi

# --list must cover every regular file in the two trees, or a config added
# later would silently go uninstalled.
n_disk="$(cd "$D" && find config home -type f -not -name .DS_Store -not -path '*/__pycache__/*' | wc -l | tr -d ' ')"
if [[ "$n_disk" == "$n_rows" ]]; then ok "--list covers every file on disk"; else err "--list reports $n_rows files but $n_disk are on disk"; fi

bad=0
for (( i = 0; i < n_rows; i++ )); do
  [[ "${targets[$i]}" == "$H"/* ]] || { err "${sources[$i]} targets ${targets[$i]}, outside the scratch home"; bad=1; }
  [[ "${modes[$i]}" == "link" || "${modes[$i]}" == "copy" ]] || { err "${sources[$i]} has mode ${modes[$i]}"; bad=1; }
done
(( bad == 0 )) && ok "every target is under the scratch home"

# With XDG_CONFIG_HOME exported, --home still wins: the whole point of the
# env -u above, asserted so it cannot regress.
xdg_list="$(HOME="$H" XDG_CONFIG_HOME="$scratch/xdg" "$SCRIPT" --list --home "$H" 2>&1)"
if [[ "$xdg_list" == *"$scratch/xdg"* ]]; then err "--home honoured XDG_CONFIG_HOME"; else ok "--home overrides XDG_CONFIG_HOME"; fi
xdg_list="$(HOME="$H" XDG_CONFIG_HOME="$scratch/xdg" "$SCRIPT" --list 2>&1)"
assert_contains "without --home, XDG_CONFIG_HOME is honoured" "$xdg_list" "$scratch/xdg/"

# --------------------------------------------------------------------------
head_ "a dry run writes nothing"
before="$(snapshot "$H" "$T")"
out="$(run_installer --dry-run 2>&1)"; rc=$?
after="$(snapshot "$H" "$T")"
assert_rc "install --dry-run exits 0 on an empty home" 0 "$rc"
assert_contains "install --dry-run previews a link" "$out" "(dry-run) ln -s"
assert_contains "install --dry-run closes with the summary line" "$out" "dry-run complete; no changes written"
if [[ "$before" == "$after" ]]; then ok "install --dry-run left the home and tmp untouched"; else err "install --dry-run wrote into the home or tmp"; fi

# --------------------------------------------------------------------------
head_ "install"
out="$(run_installer 2>&1)"; rc=$?
assert_rc "install exits 0 on an empty home" 0 "$rc"

n_links=0; n_copies=0; bad=0
for (( i = 0; i < n_rows; i++ )); do
  src="$D/${sources[$i]}"; target="${targets[$i]}"
  case "${modes[$i]}" in
    link)
      if [[ -L "$target" && "$(readlink "$target")" == "$src" ]]; then n_links=$((n_links + 1))
      else err "$target should link to $src"; bad=1; fi ;;
    copy)
      if [[ -f "$target" && ! -L "$target" ]] && cmp -s "$src" "$target"; then n_copies=$((n_copies + 1))
      else err "$target should be an identical copy of $src"; bad=1; fi ;;
  esac
done
(( bad == 0 )) && ok "every file is installed the way --list says ($n_links links, $n_copies copies)"
(( n_copies >= 1 )) || err "expected at least one copied file"

perm="$(stat -c '%a' "$H/.ssh" 2>/dev/null || stat -f '%Lp' "$H/.ssh" 2>/dev/null)"
if [[ "$perm" == "700" ]]; then ok ".ssh was created mode 700"; else err ".ssh is mode $perm, wanted 700"; fi
perm="$(stat -c '%a' "$H/.gnupg" 2>/dev/null || stat -f '%Lp' "$H/.gnupg" 2>/dev/null)"
if [[ "$perm" == "700" ]]; then ok ".gnupg was created mode 700"; else err ".gnupg is mode $perm, wanted 700"; fi

out="$(run_installer --status 2>&1)"; rc=$?
assert_rc "--status exits 0 after install" 0 "$rc"
assert_contains "--status reports MATCH" "$out" "MATCH"
if [[ "$out" == *"[ ok ]"* ]]; then err "--status lines carry a level prefix; they should be bare STATE path lines"; else ok "--status prints bare STATE path lines"; fi

before="$(snapshot "$H" "$T")"
out="$(run_installer 2>&1)"; rc=$?
after="$(snapshot "$H" "$T")"
assert_rc "a second install exits 0" 0 "$rc"
assert_contains "a second install reports already current" "$out" "already current"
if [[ "$before" == "$after" ]]; then ok "a second install changed nothing"; else err "a second install rewrote files"; fi

# A private directory that drifted is repaired by install, not only reported.
chmod 755 "$H/.ssh"
out="$(run_installer --status --only ssh 2>&1)"; rc=$?
assert_rc "--status exits 4 when .ssh is not 700" 4 "$rc"
out="$(run_installer --status --only git 2>&1)"; rc=$?
assert_rc "--status --only git ignores the mode of .ssh" 0 "$rc"
out="$(run_installer --only ssh 2>&1)"; rc=$?
assert_rc "install repairs the mode of .ssh" 0 "$rc"
perm="$(stat -c '%a' "$H/.ssh" 2>/dev/null || stat -f '%Lp' "$H/.ssh" 2>/dev/null)"
if [[ "$perm" == "700" ]]; then ok ".ssh is back to 700"; else err ".ssh is still mode $perm"; fi

# --------------------------------------------------------------------------
head_ "conflicts, --force and DRIFT"
rm "$H/.config/starship.toml"
printf 'format = "old"\n' > "$H/.config/starship.toml"
out="$(run_installer 2>&1)"; rc=$?
assert_rc "a foreign file in the way exits 4" 4 "$rc"
assert_contains "the conflict is reported" "$out" "CONFLICT, left in place"
assert_true "the foreign file was left alone" test -f "$H/.config/starship.toml" -a ! -L "$H/.config/starship.toml"

out="$(run_installer --status 2>&1)"; rc=$?
assert_rc "--status exits 4 with a conflict" 4 "$rc"
assert_contains "--status names the CONFLICT" "$out" "CONFLICT $H/.config/starship.toml"

out="$(run_installer --force --only starship 2>&1)"; rc=$?
assert_rc "--force exits 0" 0 "$rc"
assert_true "--force installed the link" test -L "$H/.config/starship.toml"
if ls "$H/.config/"starship.toml.backup-* >/dev/null 2>&1; then ok "--force kept the old file as .backup-TIMESTAMP"; else err "--force did not keep a .backup"; fi

printf '\n# local edit\n' >> "$H/.config/k9s/config.yaml"
out="$(run_installer --status --only k9s 2>&1)"; rc=$?
assert_rc "--status exits 4 on an edited copy" 4 "$rc"
assert_contains "--status reports DRIFT for an edited copy" "$out" "DRIFT"

# A directory where a copy should be is a CONFLICT, not an edited copy.
rm "$H/.config/gh/config.yml"; mkdir "$H/.config/gh/config.yml"
out="$(run_installer --status --only gh 2>&1)"; rc=$?
assert_rc "--status exits 4 on a directory at a copy target" 4 "$rc"
assert_contains "a directory at a copy target is CONFLICT" "$out" "CONFLICT"
if [[ "$out" == *"Is a directory"* ]]; then err "cmp was run against a directory"; else ok "no cmp noise for a directory"; fi
rmdir "$H/.config/gh/config.yml"
run_installer --only gh >/dev/null 2>&1

# --------------------------------------------------------------------------
head_ "uninstall"
before="$(snapshot "$H" "$T")"
out="$(run_installer --uninstall --dry-run 2>&1)"; rc=$?
after="$(snapshot "$H" "$T")"
assert_rc "uninstall --dry-run exits 0" 0 "$rc"
if [[ "$before" == "$after" ]]; then ok "uninstall --dry-run wrote nothing"; else err "uninstall --dry-run changed the home"; fi

out="$(run_installer --uninstall 2>&1)"; rc=$?
assert_rc "uninstall exits 0" 0 "$rc"
assert_contains "uninstall keeps the edited copy" "$out" "DRIFT, kept"
assert_true "the edited k9s copy survived uninstall" test -f "$H/.config/k9s/config.yaml"
bad=0
for (( i = 0; i < n_rows; i++ )); do
  target="${targets[$i]}"
  [[ "$target" == "$H/.config/k9s/config.yaml" ]] && continue
  if [[ -e "$target" || -L "$target" ]]; then err "${modes[$i]} $target was not removed"; bad=1; fi
done
(( bad == 0 )) && ok "every link and every matching copy was removed"
if ls "$H/.config/"starship.toml.backup-* >/dev/null 2>&1; then ok "the .backup was not touched by uninstall"; else err "uninstall removed the .backup"; fi
remaining="$(find "$H" -type l | wc -l | tr -d ' ')"
if [[ "$remaining" == "0" ]]; then ok "no links left behind"; else err "$remaining link(s) left behind"; fi

# --------------------------------------------------------------------------
head_ "tracked configs"
PY="$(command -v python3 || true)"
gnupg_probe="$scratch/gnupg-probe"; mkdir -p "$gnupg_probe"; chmod 700 "$gnupg_probe"

tilde='~'
n=0
copies_by_list=""
# Files for the one Python parse pass below: the interpreter starts once for
# all of them, not once per file, which was most of this suite's run time.
py_parse=()
# The heading in force when an "Installed as a copy" paragraph starts.
copies_by_readme="$(awk '/^### `~/ { h = $2; gsub(/`/, "", h) } /^Installed as a copy/ { print h }' "$D/README.md" | sort)"
for (( i = 0; i < n_rows; i++ )); do
  rel="${sources[$i]}"
  full="$D/$rel"
  n=$((n + 1))

  # No config is a program. A file marked executable here would be discovered
  # as a CLI by the static suite and asked for --help.
  if [[ -x "$full" ]]; then err "$rel is executable; configs are mode 644"; fi
  if head -n 1 "$full" | grep -q '^#!'; then err "$rel starts with a shebang"; fi

  # A config that its tool cannot parse is worse than none: the tool falls
  # back to defaults and says so once, in a line nobody reads.
  case "$rel" in
    *.toml|*.yaml|*.yml|*.json|*.py)
      if [[ -n "$PY" ]]; then py_parse+=("$rel"); else skip "$rel: no python3 to parse it"; fi ;;
    *.lua)
      if command -v luac >/dev/null 2>&1; then
        if luac -p "$full" 2>/dev/null; then ok "$rel parses as Lua"; else err "$rel is not valid Lua"; fi
      elif command -v nvim >/dev/null 2>&1; then
        if nvim --headless -u NONE -c "luafile $full" -c 'qa!' >/dev/null 2>&1; then ok "$rel loads in nvim"; else err "$rel fails to load in nvim"; fi
      else skip "$rel: no luac or nvim to parse it"; fi ;;
    home/.ssh/config)
      if command -v ssh >/dev/null 2>&1; then
        # -G resolves the config for a host and refuses on any syntax error;
        # HOME is pointed at the scratch dir so no real known_hosts is read.
        if HOME="$scratch" ssh -G -F "$full" example.invalid >/dev/null 2>&1; then ok "$rel is accepted by ssh -G"; else err "$rel is rejected by ssh -G"; fi
      else skip "$rel: no ssh to parse it"; fi ;;
    home/.gnupg/gpg.conf)
      if command -v gpg >/dev/null 2>&1; then
        if gpg --homedir "$gnupg_probe" --options "$full" --version >/dev/null 2>&1; then ok "$rel is accepted by gpg"; else err "$rel is rejected by gpg"; fi
      else skip "$rel: no gpg to parse it"; fi ;;
    home/.gnupg/gpg-agent.conf)
      if command -v gpg-agent >/dev/null 2>&1; then
        if gpg-agent --homedir "$gnupg_probe" --options "$full" --gpgconf-test >/dev/null 2>&1; then ok "$rel is accepted by gpg-agent"; else err "$rel is rejected by gpg-agent"; fi
      else skip "$rel: no gpg-agent to parse it"; fi ;;
    home/.gnupg/dirmngr.conf)
      if command -v dirmngr >/dev/null 2>&1; then
        if dirmngr --homedir "$gnupg_probe" --options "$full" --gpgconf-test >/dev/null 2>&1; then ok "$rel is accepted by dirmngr"; else err "$rel is rejected by dirmngr"; fi
      else skip "$rel: no dirmngr to parse it"; fi ;;
    config/git/config)
      if command -v git >/dev/null 2>&1; then
        if git config --file "$full" --list >/dev/null 2>&1; then ok "$rel is accepted by git config"; else err "$rel is rejected by git config"; fi
      else skip "$rel: no git to parse it"; fi ;;
  esac

  # Every config is documented: a level-three heading in dotfiles/README.md
  # naming the installed path, as --list prints it with the home as ~.
  doc="$tilde${targets[$i]#"$H"}"
  if ! grep -qF -- "### \`$doc\`" "$D/README.md"; then err "$rel is not documented in dotfiles/README.md (expected a heading \`$doc\`)"; fi
  [[ "${modes[$i]}" == "copy" ]] && copies_by_list="$copies_by_list$doc"$'\n'
done
ok "$n tracked configs inspected"

# One interpreter for every TOML, YAML, JSON and Python file. Each line the
# script prints is a verdict this harness relays: a parser module that is
# missing skips its files with a note rather than failing them, and Python
# files go through compile() rather than py_compile, which would write a
# __pycache__ into the tracked tree.
if (( ${#py_parse[@]} > 0 )); then
  while IFS=$'\t' read -r verdict message; do
    case "$verdict" in
      ok)   ok "$message" ;;
      err)  err "$message" ;;
      skip) skip "$message" ;;
    esac
  done < <(cd "$D" && "$PY" - "${py_parse[@]}" <<'PYEOF'
import json
import sys

try:
    import tomllib
except ImportError:  # python < 3.11
    tomllib = None
try:
    import yaml
except ImportError:
    yaml = None


def say(verdict, message):
    print(verdict + "\t" + message)


for rel in sys.argv[1:]:
    ext = rel.rsplit(".", 1)[-1]
    try:
        if ext == "toml":
            if tomllib is None:
                say("skip", rel + ": no tomllib (python 3.11+) to parse it")
                continue
            with open(rel, "rb") as f:
                tomllib.load(f)
            say("ok", rel + " parses as TOML")
        elif ext in ("yaml", "yml"):
            if yaml is None:
                say("skip", rel + ": no PyYAML to parse it")
                continue
            with open(rel) as f:
                list(yaml.safe_load_all(f))
            say("ok", rel + " parses as YAML")
        elif ext == "json":
            with open(rel) as f:
                json.load(f)
            say("ok", rel + " parses as JSON")
        elif ext == "py":
            with open(rel) as f:
                compile(f.read(), rel, "exec")
            say("ok", rel + " compiles as Python")
    except Exception as exc:  # any parse failure is the finding
        say("err", rel + " does not parse: " + str(exc).splitlines()[0])
PYEOF
  )
fi

# The link-or-copy decision lives in copy_mode(); the README says "Installed
# as a copy" under each copied file. The two lists must be the same list.
copies_by_list="$(printf '%s' "$copies_by_list" | sort)"
if [[ "$copies_by_list" == "$copies_by_readme" ]]; then
  ok "the copied files are exactly the ones the README says are copies"
else
  err "copy_mode() and the README disagree on which files are copies"
  printf 'installer: %s\nREADME:    %s\n' "$(printf '%s' "$copies_by_list" | tr '\n' ' ')" "$(printf '%s' "$copies_by_readme" | tr '\n' ' ')" >&2
fi

# Nothing tracked here may carry a credential. These configs are meant to be
# public; every tool that needs a token reads it from a file that is not here.
if grep -rnE '(AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY|ghp_[A-Za-z0-9]{20,}|glpat-[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|aws_secret_access_key *=|oauth_token: *[A-Za-z0-9])' "$D/config" "$D/home"; then
  err "a tracked config contains something that looks like a credential"
else
  ok "no tracked config looks like it carries a credential"
fi

# --------------------------------------------------------------------------
printf '\n'
if (( failures > 0 )); then
  printf '%s dotfiles check(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'all dotfiles checks passed\n'
