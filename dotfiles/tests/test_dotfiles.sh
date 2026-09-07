#!/usr/bin/env bash
# Contract and behaviour checks for dotfiles/.
#
# Two halves. The first runs install_dotfiles.sh against a scratch home and
# asserts what it promises: --help before preflight, exit 3 on a bad flag, a
# dry run that writes nothing, links that point at this folder, copies for the
# files their tools rewrite, conflicts left in place, --force moving them to a
# .bak, --status telling MATCH from DRIFT, and an uninstall that removes only
# what it made. The second reads the tracked configs themselves: every file
# parses in the format its tool expects (where a parser is available), none is
# executable, none carries a secret, and the README names every one of them.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
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
assert_contains() {
  local label="$1" needle="$2" hay="$3"
  if [[ "$hay" == *"$needle"* ]]; then ok "$label"; else err "$label (missing: $needle)"; fi
}

TIMEOUT_BIN="$(command -v timeout || true)"
if [[ -n "$TIMEOUT_BIN" ]]; then guard() { "$TIMEOUT_BIN" 20 "$@"; }; else guard() { "$@"; }; fi

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
H="$scratch/home"
mkdir -p "$H"

snapshot() { find "$1" -mindepth 1 -printf '%p %T@\n' 2>/dev/null | sort; }
# macOS find has no -printf; fall back to names and sizes there.
if ! find "$scratch" -maxdepth 0 -printf '' >/dev/null 2>&1; then
  snapshot() { find "$1" -mindepth 1 -exec ls -ld {} \; 2>/dev/null | sort; }
fi

# --------------------------------------------------------------------------
head_ "CLI contract"
out="$(guard "$SCRIPT" --help 2>&1)"; rc=$?
assert_rc "--help exits 0" 0 "$rc"
assert_contains "--help documents --dry-run" "--dry-run" "$out"
assert_contains "--help documents the exit codes" "Exit codes:" "$out"

guard "$SCRIPT" --definitely-not-a-flag >/dev/null 2>&1; rc=$?
assert_rc "unknown flag exits 3" 3 "$rc"
guard "$SCRIPT" --only >/dev/null 2>&1; rc=$?
assert_rc "--only without a value exits 3" 3 "$rc"
guard "$SCRIPT" --status --uninstall --home "$H" >/dev/null 2>&1; rc=$?
assert_rc "two modes at once exit 3" 3 "$rc"
guard "$SCRIPT" --home "$scratch/does-not-exist" >/dev/null 2>&1; rc=$?
assert_rc "a missing home directory exits 2" 2 "$rc"
guard "$SCRIPT" --status --home "$H" --only no-such-unit >/dev/null 2>&1; rc=$?
assert_rc "an unknown --only unit exits 3" 3 "$rc"

out="$(guard "$SCRIPT" --list 2>&1)"; rc=$?
assert_rc "--list exits 0" 0 "$rc"
assert_contains "--list names the k9s unit" "k9s" "$out"
assert_contains "--list names the git unit" "git" "$out"

# --------------------------------------------------------------------------
head_ "a dry run writes nothing"
before="$(snapshot "$H")"
out="$(HOME="$H" guard "$SCRIPT" --dry-run --home "$H" 2>&1)"; rc=$?
after="$(snapshot "$H")"
assert_rc "install --dry-run exits 0 on an empty home" 0 "$rc"
assert_contains "install --dry-run previews a link" "(dry-run) ln -s" "$out"
assert_contains "install --dry-run closes with the summary line" "dry-run complete; no changes written" "$out"
if [[ "$before" == "$after" ]]; then ok "install --dry-run left the home untouched"; else err "install --dry-run wrote into the home"; fi

# --------------------------------------------------------------------------
head_ "install"
out="$(HOME="$H" guard "$SCRIPT" --home "$H" 2>&1)"; rc=$?
assert_rc "install exits 0 on an empty home" 0 "$rc"

n_links=0; n_copies=0; bad=0
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  rel="${f#./}"
  case "$rel" in
    config/*) target="$H/.config/${rel#config/}" ;;
    home/*)   target="$H/${rel#home/}" ;;
  esac
  if [[ -L "$target" ]]; then
    if [[ "$(readlink "$target")" == "$D/$rel" ]]; then n_links=$((n_links + 1)); else err "$target links to $(readlink "$target")"; bad=1; fi
  elif [[ -f "$target" ]]; then
    if cmp -s "$D/$rel" "$target"; then n_copies=$((n_copies + 1)); else err "$target is a copy that differs from $rel"; bad=1; fi
  else
    err "$target was not installed"; bad=1
  fi
done < <(cd "$D" && find ./config ./home -type f -not -path '*/__pycache__/*' | sort)
(( bad == 0 )) && ok "every tracked file is installed ($n_links links, $n_copies copies)"
(( n_copies >= 1 )) || err "expected at least one copied file (k9s config.yaml)"
[[ -L "$H/.config/k9s/config.yaml" ]] && err "k9s config.yaml must be copied, not linked - k9s rewrites it on exit"
[[ -f "$H/.config/k9s/config.yaml" && ! -L "$H/.config/k9s/config.yaml" ]] && ok "k9s config.yaml is a copy"
[[ -L "$H/.config/starship.toml" ]] && ok "starship.toml is a link"

perm="$(stat -c '%a' "$H/.ssh" 2>/dev/null || stat -f '%Lp' "$H/.ssh" 2>/dev/null)"
if [[ "$perm" == "700" ]]; then ok ".ssh was created mode 700"; else err ".ssh is mode $perm, wanted 700"; fi
perm="$(stat -c '%a' "$H/.gnupg" 2>/dev/null || stat -f '%Lp' "$H/.gnupg" 2>/dev/null)"
if [[ "$perm" == "700" ]]; then ok ".gnupg was created mode 700"; else err ".gnupg is mode $perm, wanted 700"; fi

out="$(HOME="$H" guard "$SCRIPT" --status --home "$H" 2>&1)"; rc=$?
assert_rc "--status exits 0 after install" 0 "$rc"
assert_contains "--status reports MATCH" "MATCH" "$out"

before="$(snapshot "$H")"
out="$(HOME="$H" guard "$SCRIPT" --home "$H" 2>&1)"; rc=$?
after="$(snapshot "$H")"
assert_rc "a second install exits 0" 0 "$rc"
assert_contains "a second install reports already current" "already current" "$out"
if [[ "$before" == "$after" ]]; then ok "a second install changed nothing"; else err "a second install rewrote files"; fi

# --------------------------------------------------------------------------
head_ "conflicts, --force and DRIFT"
rm "$H/.config/starship.toml"
printf 'format = "old"\n' > "$H/.config/starship.toml"
out="$(HOME="$H" guard "$SCRIPT" --home "$H" 2>&1)"; rc=$?
assert_rc "a foreign file in the way exits 4" 4 "$rc"
assert_contains "the conflict is reported" "CONFLICT, left in place" "$out"
[[ -f "$H/.config/starship.toml" && ! -L "$H/.config/starship.toml" ]] && ok "the foreign file was left alone"

out="$(HOME="$H" guard "$SCRIPT" --status --home "$H" 2>&1)"; rc=$?
assert_rc "--status exits 4 with a conflict" 4 "$rc"

out="$(HOME="$H" guard "$SCRIPT" --home "$H" --force --only starship 2>&1)"; rc=$?
assert_rc "--force exits 0" 0 "$rc"
[[ -L "$H/.config/starship.toml" ]] && ok "--force installed the link"
if ls "$H/.config/"starship.toml.bak-* >/dev/null 2>&1; then ok "--force kept the old file as .bak"; else err "--force did not keep a .bak"; fi

printf '\n# local edit\n' >> "$H/.config/k9s/config.yaml"
out="$(HOME="$H" guard "$SCRIPT" --status --home "$H" --only k9s 2>&1)"; rc=$?
assert_rc "--status exits 4 on an edited copy" 4 "$rc"
assert_contains "--status reports DRIFT for an edited copy" "DRIFT" "$out"

# --------------------------------------------------------------------------
head_ "uninstall"
before="$(snapshot "$H")"
out="$(HOME="$H" guard "$SCRIPT" --uninstall --dry-run --home "$H" 2>&1)"; rc=$?
after="$(snapshot "$H")"
assert_rc "uninstall --dry-run exits 0" 0 "$rc"
if [[ "$before" == "$after" ]]; then ok "uninstall --dry-run wrote nothing"; else err "uninstall --dry-run changed the home"; fi

out="$(HOME="$H" guard "$SCRIPT" --uninstall --home "$H" 2>&1)"; rc=$?
assert_rc "uninstall exits 0" 0 "$rc"
assert_contains "uninstall keeps the edited copy" "DRIFT, kept" "$out"
[[ -f "$H/.config/k9s/config.yaml" ]] && ok "the edited k9s copy survived uninstall"
[[ ! -e "$H/.config/starship.toml" ]] && ok "the starship link was removed"
[[ ! -e "$H/.ssh/config" ]] && ok "the ssh config link was removed"
if ls "$H/.config/"starship.toml.bak-* >/dev/null 2>&1; then ok "the .bak was not touched by uninstall"; else err "uninstall removed the .bak"; fi
remaining="$(find "$H" -type l | wc -l | tr -d ' ')"
if [[ "$remaining" == "0" ]]; then ok "no links left behind"; else err "$remaining link(s) left behind"; fi

# --------------------------------------------------------------------------
head_ "tracked configs"
PY="$(command -v python3 || true)"
py_has() { [[ -n "$PY" ]] && "$PY" -c "import $1" >/dev/null 2>&1; }

n=0
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  rel="${f#./}"
  n=$((n + 1))
  full="$D/$rel"

  # No config is a program. A file marked executable here would be discovered
  # as a CLI by the static suite and asked for --help.
  if [[ -x "$full" ]]; then err "$rel is executable; configs are mode 644"; fi
  if head -n 1 "$full" | grep -q '^#!'; then err "$rel starts with a shebang"; fi

  # A config that its tool cannot parse is worse than none: the tool falls
  # back to defaults and says so once, in a line nobody reads.
  case "$rel" in
    *.toml)
      if py_has tomllib; then
        if "$PY" -c "import sys,tomllib; tomllib.load(open(sys.argv[1],'rb'))" "$full" 2>/dev/null; then ok "$rel parses as TOML"; else err "$rel is not valid TOML"; fi
      else skip "$rel: no tomllib (python 3.11+) to parse it"; fi ;;
    *.yaml|*.yml)
      if py_has yaml; then
        if "$PY" -c "import sys,yaml; list(yaml.safe_load_all(open(sys.argv[1])))" "$full" 2>/dev/null; then ok "$rel parses as YAML"; else err "$rel is not valid YAML"; fi
      else skip "$rel: no PyYAML to parse it"; fi ;;
    *.json)
      if [[ -n "$PY" ]]; then
        if "$PY" -c "import sys,json; json.load(open(sys.argv[1]))" "$full" 2>/dev/null; then ok "$rel parses as JSON"; else err "$rel is not valid JSON"; fi
      else skip "$rel: no python3 to parse it"; fi ;;
    *.lua)
      if command -v luac >/dev/null 2>&1; then
        if luac -p "$full" 2>/dev/null; then ok "$rel parses as Lua"; else err "$rel is not valid Lua"; fi
      elif command -v nvim >/dev/null 2>&1; then
        if nvim --headless -u NONE -c "luafile $full" -c 'qa!' >/dev/null 2>&1; then ok "$rel loads in nvim"; else err "$rel fails to load in nvim"; fi
      else skip "$rel: no luac or nvim to parse it"; fi ;;
    *.py)
      if [[ -n "$PY" ]]; then
        # compile() rather than py_compile: the latter writes a __pycache__
        # into the tracked tree, which this very loop then discovers.
        if "$PY" -c "import sys; compile(open(sys.argv[1]).read(), sys.argv[1], 'exec')" "$full" 2>/dev/null; then ok "$rel compiles as Python"; else err "$rel is not valid Python"; fi
      else skip "$rel: no python3 to parse it"; fi ;;
    home/.ssh/config)
      if command -v ssh >/dev/null 2>&1; then
        # -G resolves the config for a host and refuses on any syntax error;
        # HOME is pointed at the scratch dir so no real known_hosts is read.
        if HOME="$scratch" ssh -G -F "$full" example.invalid >/dev/null 2>&1; then ok "$rel is accepted by ssh -G"; else err "$rel is rejected by ssh -G"; fi
      else skip "$rel: no ssh to parse it"; fi ;;
    home/.gnupg/gpg.conf)
      if command -v gpg >/dev/null 2>&1; then
        if GNUPGHOME="$scratch/gnupg-probe" gpg --homedir "$scratch/gnupg-probe" --options "$full" --version >/dev/null 2>&1; then ok "$rel is accepted by gpg"; else err "$rel is rejected by gpg"; fi
      else skip "$rel: no gpg to parse it"; fi ;;
    config/git/config)
      if command -v git >/dev/null 2>&1; then
        if git config --file "$full" --list >/dev/null 2>&1; then ok "$rel is accepted by git config"; else err "$rel is rejected by git config"; fi
      fi ;;
  esac

  # Every config is documented: a level-two heading in dotfiles/README.md
  # naming the target path. test_doc_citations.sh checks the script; this is
  # the same promise for the files the script installs.
  tilde='~'
  case "$rel" in
    config/*) target="$tilde/.config/${rel#config/}" ;;
    *)        target="$tilde/${rel#home/}" ;;
  esac
  if ! grep -qF -- "\`$target\`" "$D/README.md"; then err "$rel is not documented in dotfiles/README.md (expected \`$target\`)"; fi
done < <(cd "$D" && find ./config ./home -type f -not -path '*/__pycache__/*' | sort)
ok "$n tracked configs inspected"

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
