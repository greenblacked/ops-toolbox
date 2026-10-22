#!/usr/bin/env bash
# Contract and behaviour checks for dotfiles/.
#
# Two halves. The first runs install_dotfiles.sh against a scratch home and
# asserts what it promises: --help before preflight, exit 3 on a bad flag, a
# dry run that writes nothing, links that point at this folder, copies for the
# files their tools rewrite, conflicts left in place, --force moving them to a
# .backup, --status telling MATCH from DRIFT, --diff showing what a drifted
# file differs by with credentials redacted, and an uninstall that removes
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
head_ "groups"
# The units of a --list run, one per line, header dropped.
list_units() { awk 'NR > 1 { print $1 }' <<<"$1" | sort -u | tr '\n' ' '; }

groups_out="$(run_installer --groups 2>&1)"; rc=$?
assert_rc "--groups exits 0" 0 "$rc"
for g in shell terminal git access k8s cloud scanners packages server; do
  assert_contains "--groups lists @$g" "$groups_out" $'\n'"$g "
done

# Every row, read from --groups itself: --only @NAME must select exactly the
# units the row names, no more and no fewer.
n_groups=0
covered=" "
while read -r g members; do
  [[ -z "$g" || "$g" == "GROUP" ]] && continue
  n_groups=$((n_groups + 1))
  [[ "$g" == "server" ]] || covered="$covered$members "
  out="$(run_installer --list --only "@$g" 2>&1)"; rc=$?
  [[ "$rc" == 0 ]] || err "--list --only @$g exited $rc"
  got="$(list_units "$out")"
  want="$(tr ' ' '\n' <<<"$members" | sort -u | tr '\n' ' ')"
  if [[ "$got" == "$want" ]]; then ok "@$g selects exactly its units"; else err "@$g selects '$got', expected '$want'"; fi
done <<< "$groups_out"
(( n_groups > 0 )) || err "--groups listed no group"

# Whoever adds a config has to place it: every unit belongs to some group
# other than server, the way every file needs a README heading.
bad=0
for u in "${units[@]}"; do
  [[ "$covered" == *" $u "* ]] || { err "unit $u is in no group but server; add it to group_units()"; bad=1; }
done
(( bad == 0 )) && ok "every unit belongs to a group"

run_installer --list --only @nope >/dev/null 2>&1; rc=$?
assert_rc "an unknown group exits 3" 3 "$rc"
out="$(run_installer --list --only @nope 2>&1)"
assert_contains "an unknown group is named" "$out" "no such group: @nope"
run_installer --list --only @ >/dev/null 2>&1; rc=$?
assert_rc "an empty group name exits 3" 3 "$rc"
out="$(run_installer --list --only @k8s,starship 2>&1)"; rc=$?
assert_rc "a group and a unit combine" 0 "$rc"
assert_contains "a group and a unit combine" "$(list_units "$out")" "k9s kube starship "

before="$(snapshot "$H" "$T")"
out="$(run_installer --dry-run --only @server 2>&1)"; rc=$?
after="$(snapshot "$H" "$T")"
assert_rc "--dry-run --only @server exits 0" 0 "$rc"
assert_contains "@server previews the ssh config" "$out" "(dry-run) ln -s $D/home/.ssh/config"
assert_contains "@server previews the git config" "$out" "(dry-run) ln -s $D/config/git/config"
if [[ "$out" == *kitty* ]]; then err "@server previewed kitty"; else ok "@server leaves the GUI terminals out"; fi
if [[ "$before" == "$after" ]]; then ok "--dry-run --only @server wrote nothing"; else err "--dry-run --only @server wrote into the home or tmp"; fi
run_installer --groups --dry-run >/dev/null 2>&1; rc=$?
assert_rc "--groups --dry-run exits 3" 3 "$rc"
run_installer --groups --status >/dev/null 2>&1; rc=$?
assert_rc "--groups --status exits 3" 3 "$rc"

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
head_ "orphans and --prune"
# Three links no tracked file installs to: one left by a config renamed away
# (dangling), one at an untracked path pointing at a live file here, and one
# that is not ours at all and must never be reported or removed.
mkdir -p "$H/.config/oldtool"
ln -s "$D/config/oldtool/config" "$H/.config/oldtool/config"
ln -s "$D/config/starship.toml" "$H/.config/starship-copy.toml"
ln -s /etc/hosts "$H/.config/not-ours"
# A link --force moved aside is a backup, and backups are never removed.
ln -s "$D/config/starship.toml" "$H/.config/starship.toml.backup-20200101-000000"

out="$(run_installer --status 2>&1)"; rc=$?
assert_rc "--status exits 4 with orphan links" 4 "$rc"
assert_contains "--status reports the dangling orphan" "$out" "ORPHAN  $H/.config/oldtool/config"
assert_contains "--status reports the untracked live link" "$out" "ORPHAN  $H/.config/starship-copy.toml"
if [[ "$out" == *"not-ours"* ]]; then err "--status reported a link that does not point into this folder"; else ok "--status ignores a link that is not ours"; fi
if [[ "$out" == *".backup-"* ]]; then err "--status reported a backup link as an orphan"; else ok "--status ignores a backup link"; fi
out="$(run_installer --status --only git 2>&1)"; rc=$?
assert_rc "--status --only git exits 0 with orphans outside the unit" 0 "$rc"
if [[ "$out" == *"ORPHAN"* ]]; then err "--status --only git reported orphans of other units"; else ok "--only filters orphans by unit"; fi

before="$(snapshot "$H" "$T")"
out="$(run_installer --prune --dry-run 2>&1)"; rc=$?
after="$(snapshot "$H" "$T")"
assert_rc "--prune --dry-run exits 0" 0 "$rc"
assert_contains "--prune --dry-run previews the rm" "$out" "(dry-run) rm $H/.config/oldtool/config"
assert_contains "--prune --dry-run closes with the summary line" "$out" "dry-run complete; no changes written"
if [[ "$before" == "$after" ]]; then ok "--prune --dry-run wrote nothing"; else err "--prune --dry-run changed the home"; fi

out="$(run_installer --prune 2>&1)"; rc=$?
assert_rc "--prune exits 0" 0 "$rc"
assert_contains "--prune counts what it removed" "$out" "2 orphan link(s) removed"
assert_true "--prune removed the dangling orphan" test ! -L "$H/.config/oldtool/config"
assert_true "--prune removed the untracked live link" test ! -L "$H/.config/starship-copy.toml"
assert_true "--prune left a link that is not ours" test -L "$H/.config/not-ours"
assert_true "--prune left the backup link" test -L "$H/.config/starship.toml.backup-20200101-000000"
assert_true "--prune left the emptied directory in place" test -d "$H/.config/oldtool"
assert_true "--prune left the tracked links alone" test -L "$H/.config/starship.toml"
out="$(run_installer --prune 2>&1)"; rc=$?
assert_rc "a second --prune exits 0" 0 "$rc"
assert_contains "a second --prune finds nothing" "$out" "0 orphan link(s) removed"
run_installer --prune --force >/dev/null 2>&1; rc=$?
assert_rc "--prune --force exits 3" 3 "$rc"
run_installer --prune --status >/dev/null 2>&1; rc=$?
assert_rc "--prune --status exits 3" 3 "$rc"
rm "$H/.config/not-ours" "$H/.config/starship.toml.backup-20200101-000000"; rmdir "$H/.config/oldtool"
out="$(run_installer --status 2>&1)"; rc=$?
assert_rc "--status exits 0 again after --prune" 0 "$rc"

# A whole source directory deleted from home/ (no .foo there any more) still
# leaves ~/.foo/config behind; the scan must reach it through the home itself.
mkdir -p "$H/.foo"
ln -s "$D/home/.foo/config" "$H/.foo/config"
out="$(run_installer --status 2>&1)"; rc=$?
assert_rc "--status exits 4 with an orphan under a deleted source directory" 4 "$rc"
assert_contains "--status reports the orphan under a deleted source directory" "$out" "ORPHAN  $H/.foo/config"
out="$(run_installer --prune --dry-run 2>&1)"; rc=$?
assert_rc "--prune --dry-run exits 0 for a deleted source directory" 0 "$rc"
assert_contains "--prune --dry-run previews removing it" "$out" "(dry-run) rm $H/.foo/config"
assert_true "--prune --dry-run kept the link" test -L "$H/.foo/config"
# The unit of a wholly deleted source directory is a valid --only for
# --prune, as the bare scan finds it; any other mode and any unit with no
# orphan still exit 3.
out="$(run_installer --prune --only foo --dry-run 2>&1)"; rc=$?
assert_rc "--prune --only <deleted unit> exits 0" 0 "$rc"
assert_contains "--prune --only <deleted unit> previews the rm" "$out" "(dry-run) rm $H/.foo/config"
run_installer --prune --only nosuchunit --dry-run >/dev/null 2>&1; rc=$?
assert_rc "--prune --only <unit with no orphan> exits 3" 3 "$rc"
run_installer --status --only foo >/dev/null 2>&1; rc=$?
assert_rc "--status --only <deleted unit> still exits 3" 3 "$rc"
out="$(run_installer --prune --only git --dry-run 2>&1)"
if [[ "$out" == *"$H/.foo/config"* ]]; then err "--prune --only git touched another unit's orphan"; else ok "--prune --only <unit> leaves other units' orphans"; fi
out="$(run_installer --prune 2>&1)"; rc=$?
assert_rc "--prune exits 0 for a deleted source directory" 0 "$rc"
assert_contains "--prune counts the removed link" "$out" "1 orphan link(s) removed"
assert_true "--prune removed the link under a deleted source directory" test ! -L "$H/.foo/config"
rmdir "$H/.foo"

# --------------------------------------------------------------------------
head_ "backups and --restore"
st="$H/.config/starship.toml"
rm "$st"
printf 'original\n' > "$st"
run_installer --force --only starship >/dev/null 2>&1 || err "--force did not install over the original"
out="$(run_installer --backups --only starship 2>&1)"; rc=$?
assert_rc "--backups exits 0" 0 "$rc"
assert_contains "--backups lists the backup --force made" "$out" "BACKUP  "
assert_contains "--backups prints the backup path" "$out" "$st.backup-"

before="$(snapshot "$H" "$T")"
out="$(run_installer --restore --dry-run --only starship 2>&1)"; rc=$?
after="$(snapshot "$H" "$T")"
assert_rc "--restore --dry-run exits 0" 0 "$rc"
assert_contains "--restore --dry-run previews the move" "$out" "(dry-run) mv $st.backup-"
assert_contains "--restore --dry-run closes with the summary line" "$out" "dry-run complete; no changes written"
if [[ "$before" == "$after" ]]; then ok "--restore --dry-run wrote nothing"; else err "--restore --dry-run changed the home"; fi

out="$(run_installer --restore --only starship 2>&1)"; rc=$?
assert_rc "--restore exits 0" 0 "$rc"
assert_true "--restore put a regular file back" test -f "$st" -a ! -L "$st"
assert_true "--restore put the original content back" grep -qx original "$st"
if ls "$st".backup-* >/dev/null 2>&1; then err "--restore left the backup behind"; else ok "--restore moved the backup into place"; fi
out="$(run_installer --restore --only starship 2>&1)"; rc=$?
assert_rc "a second --restore exits 4" 4 "$rc"
assert_contains "a second --restore says there is no backup" "$out" "no backup"

# A file holding changes is never overwritten by a restore.
run_installer --force --only starship >/dev/null 2>&1 || err "--force did not install over the restored file"
rm "$st"
printf 'edited\n' > "$st"
out="$(run_installer --restore --only starship 2>&1)"; rc=$?
assert_rc "--restore over a changed file exits 4" 4 "$rc"
assert_contains "--restore reports the file left in place" "$out" "left in place"
assert_true "the changed file survived" grep -qx edited "$st"
if ls "$st".backup-* >/dev/null 2>&1; then ok "the backup was kept"; else err "the backup was lost"; fi

# Newest by default, an older one by --stamp.
rm -f "$st" "$st".backup-*
printf 'older\n' > "$st.backup-20200101-000000"
printf 'newer\n' > "$st.backup-20210101-000000"
out="$(run_installer --restore --only starship 2>&1)"; rc=$?
assert_rc "--restore with two backups exits 0" 0 "$rc"
assert_true "the newest backup is the default" grep -qx newer "$st"
assert_true "the older backup is still there" test -f "$st.backup-20200101-000000"
rm "$st"
out="$(run_installer --restore --stamp 20200101-000000 --only starship 2>&1)"; rc=$?
assert_rc "--restore --stamp exits 0" 0 "$rc"
assert_true "--stamp restores the backup it names" grep -qx older "$st"

run_installer --restore --stamp bogus >/dev/null 2>&1; rc=$?
assert_rc "a malformed --stamp exits 3" 3 "$rc"
run_installer --restore --stamp=../../x >/dev/null 2>&1; rc=$?
assert_rc "a path in --stamp= exits 3" 3 "$rc"
run_installer --stamp 20200101-000000 >/dev/null 2>&1; rc=$?
assert_rc "--stamp without --restore exits 3" 3 "$rc"
run_installer --restore --force >/dev/null 2>&1; rc=$?
assert_rc "--restore --force exits 3" 3 "$rc"
run_installer --backups --dry-run >/dev/null 2>&1; rc=$?
assert_rc "--backups --dry-run exits 3" 3 "$rc"

# A config renamed or deleted in the repository after --force backed it up:
# nothing tracked points at the path any more, but the backup is still
# there and must be listed and restorable. The orphan link stands in for
# what the old install left at the path.
mkdir -p "$H/.config/oldtool"
old="$H/.config/oldtool/x"
printf 'before-rename\n' > "$old.backup-20200101-000000"
printf 'not-ours\n' > "$old.backup-bogus"
ln -s "$D/config/oldtool/x" "$old"
out="$(run_installer --backups 2>&1)"; rc=$?
assert_rc "--backups exits 0 with a stray backup" 0 "$rc"
assert_contains "--backups lists a backup of a path no file installs to" "$out" "BACKUP  20200101-000000  $old.backup-20200101-000000"
if [[ "$out" == *"backup-bogus"* ]]; then err "--backups listed a name that is not NAME.backup-STAMP"; else ok "--backups skips a malformed backup name"; fi
out="$(run_installer --backups --only starship 2>&1)"
if [[ "$out" == *"oldtool"* ]]; then err "--backups --only starship listed another unit's backup"; else ok "--backups --only leaves other units' stray backups"; fi
out="$(run_installer --backups --only oldtool 2>&1)"
assert_contains "--backups --only selects a stray backup by its unit" "$out" "$old.backup-20200101-000000"

before="$(snapshot "$H" "$T")"
out="$(run_installer --restore --dry-run --only oldtool 2>&1)"; rc=$?
after="$(snapshot "$H" "$T")"
assert_rc "--restore --dry-run of a stray backup exits 0" 0 "$rc"
if [[ "$before" == "$after" ]]; then ok "--restore --dry-run of a stray backup wrote nothing"; else err "--restore --dry-run of a stray backup changed the home"; fi

# A stray path in a unit this installer tracks, holding an edit: refused.
gold="$H/.config/git/oldname"
mkdir -p "$H/.config/git"
printf 'before-rename\n' > "$gold.backup-20200101-000000"
printf 'edited\n' > "$gold"
out="$(run_installer --restore --only git 2>&1)"; rc=$?
assert_rc "--restore over a changed stray path exits 4" 4 "$rc"
assert_true "the changed stray file survived" grep -qx edited "$gold"
assert_true "the stray backup was kept" test -f "$gold.backup-20200101-000000"
rm -f "$gold" "$gold.backup-20200101-000000"
rmdir "$H/.config/git" 2>/dev/null || true

rm "$old"; ln -s "$D/config/oldtool/x" "$old"
out="$(run_installer --restore --only oldtool 2>&1)"; rc=$?
assert_rc "--restore of a stray backup exits 0" 0 "$rc"
assert_true "--restore put the stray backup back over the orphan link" grep -qx before-rename "$old"
assert_true "--restore consumed the stray backup" test ! -e "$old.backup-20200101-000000"
rm -f "$old" "$old.backup-bogus"; rmdir "$H/.config/oldtool"

# Two backups of a deleted unit: restoring the newest leaves a regular file
# where the link was, yet the older one stays listed and restorable (the
# installer remembers it restored that path), and nothing is left behind
# once the last backup is back.
mkdir -p "$H/.config/oldtool"
old="$H/.config/oldtool/y"
printf 'older\n' > "$old.backup-20200101-000000"
printf 'newer\n' > "$old.backup-20200202-000000"
ln -s "$D/config/oldtool/y" "$old"
out="$(run_installer --restore --only oldtool 2>&1)"; rc=$?
assert_rc "--restore of two stray backups exits 0" 0 "$rc"
assert_true "--restore put the newest stray backup back" grep -qx newer "$old"
out="$(run_installer --backups --only oldtool 2>&1)"; rc=$?
assert_rc "--backups --only after restoring the newest exits 0" 0 "$rc"
assert_contains "the older stray backup is still listed" "$out" "BACKUP  20200101-000000  $old.backup-20200101-000000"
out="$(run_installer --restore --stamp 20200101-000000 --only oldtool 2>&1)"; rc=$?
assert_rc "--restore --stamp over the restored file is refused" 4 "$rc"
assert_true "the restored file survived the refusal" grep -qx newer "$old"
rm "$old"
out="$(run_installer --restore --stamp 20200101-000000 --only oldtool 2>&1)"; rc=$?
assert_rc "--restore --stamp of the older stray backup exits 0" 0 "$rc"
assert_true "--restore put the older stray backup back" grep -qx older "$old"
assert_true "the restore ledger is gone with the last backup" test ! -e "$H/.dotfiles-restored"
rm -f "$old"; rmdir "$H/.config/oldtool"

# NAME.backup-STAMP is a name other tools use too. With no link into this
# folder and no unit of ours at the path, it is not ours: listed as such,
# never restored, and not a unit --only may name.
mkdir -p "$H/.config/othertool"
other="$H/.config/othertool/y"
printf 'theirs\n' > "$other.backup-20200101-000000"
out="$(run_installer --backups 2>&1)"
if [[ "$out" == *"BACKUP"*"$other"* ]]; then err "--backups listed another tool's backup"; else ok "--backups skips a backup that is not ours"; fi
assert_contains "--backups says a backup is not ours" "$out" "not ours, skipped: $other.backup-20200101-000000"
out="$(run_installer --restore --dry-run 2>&1)"
if [[ "$out" == *"mv $other.backup"* ]]; then err "bare --restore would restore another tool's backup"; else ok "bare --restore leaves another tool's backup alone"; fi
run_installer --restore --only othertool >/dev/null 2>&1; rc=$?
assert_rc "--restore --only a unit with only a foreign backup exits 3" 3 "$rc"
rm -f "$other.backup-20200101-000000"; rmdir "$H/.config/othertool"

rm -f "$st" "$st".backup-*
run_installer --only starship >/dev/null 2>&1 || err "could not relink starship.toml after the restore checks"

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

# Two forced replacements in one second must keep two distinct backups.
# A fake date pins the stamp so the second run is certain to collide.
fk="$T/fakebin"; mkdir -p "$fk"
printf '#!/bin/sh\necho 20300101-000000\n' > "$fk/date"; chmod +x "$fk/date"
rm -f "$H/.config/starship.toml" "$H/.config/"starship.toml.backup-*
printf 'first\n' > "$H/.config/starship.toml"
PATH="$fk:$PATH" run_installer --force --only starship >/dev/null 2>&1; rc=$?
assert_rc "first same-second --force exits 0" 0 "$rc"
rm -f "$H/.config/starship.toml"; printf 'second\n' > "$H/.config/starship.toml"
PATH="$fk:$PATH" run_installer --force --only starship >/dev/null 2>&1; rc=$?
assert_rc "second same-second --force exits 0" 0 "$rc"
assert_true "the first backup kept its content" grep -qx first "$H/.config/starship.toml.backup-20300101-000000"
assert_true "the second backup got a suffixed name" grep -qx second "$H/.config/starship.toml.backup-20300101-000000-1"
out="$(run_installer --backups --only starship 2>&1)"
assert_contains "--backups lists the suffixed backup" "$out" "20300101-000000-1"
rm -f "$H/.config/starship.toml"
run_installer --restore --only starship >/dev/null 2>&1; rc=$?
assert_rc "--restore exits 0" 0 "$rc"
assert_true "--restore picks the newest (suffixed) backup" grep -qx second "$H/.config/starship.toml"
run_installer --force --only starship >/dev/null 2>&1

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
head_ "--diff"
# The k9s copy still carries the '# local edit' line from the section above.
before="$(snapshot "$H" "$T")"
out="$(run_installer --diff --only k9s 2>&1)"; rc=$?
after="$(snapshot "$H" "$T")"
assert_rc "--diff exits 4 when a copy has drifted" 4 "$rc"
assert_contains "--diff names the DRIFT file" "$out" "DRIFT    $H/.config/k9s/config.yaml"
assert_contains "--diff shows the local edit as an added line" "$out" "+# local edit"
if [[ "$out" == *"$D/config/k9s/config.yaml"* ]]; then err "--diff printed the diff header with the source path"; else ok "--diff drops the path and timestamp header"; fi
if [[ "$before" == "$after" ]]; then ok "--diff wrote nothing"; else err "--diff wrote into the home or tmp"; fi

out="$(run_installer --diff --only git 2>&1)"; rc=$?
assert_rc "--diff exits 0 when every selected file matches" 0 "$rc"
if [[ -z "$out" ]]; then ok "--diff prints nothing for matching files"; else err "--diff printed output for matching files: $out"; fi

rm "$H/.config/starship.toml"
printf 'format = "old"\n' > "$H/.config/starship.toml"
out="$(run_installer --diff --only starship 2>&1)"; rc=$?
assert_rc "--diff exits 4 on a CONFLICT file" 4 "$rc"
if [[ "$out" == CONFLICT* ]]; then ok "--diff output starts with the CONFLICT header"; else err "--diff output does not start with CONFLICT: $out"; fi
assert_contains "--diff shows the source lines as removed" "$out" $'\n-'
assert_contains "--diff shows the file on disk as added" "$out" '+format = "old"'
rm "$H/.config/starship.toml"
run_installer --only starship >/dev/null 2>&1 || err "could not relink starship.toml after the --diff check"

rm "$H/.config/gh/config.yml"; mkdir "$H/.config/gh/config.yml"
out="$(run_installer --diff --only gh 2>&1)"; rc=$?
assert_rc "--diff exits 4 on a directory at a target" 4 "$rc"
assert_contains "--diff notes a directory instead of diffing it" "$out" "  is a directory"
if [[ "$out" == *"Is a directory"* ]]; then err "diff was run against a directory"; else ok "no diff noise for a directory"; fi
rmdir "$H/.config/gh/config.yml"
run_installer --only gh >/dev/null 2>&1 || err "could not restore gh/config.yml after the --diff check"

# A drifted docker copy is where a real credential sits after `docker login`.
# The value is assembled here so no literal sits in this file.
secret="$(printf 'c2VjcmV0%s' 'c2VjcmV0')"
printf '{"auths":{"x":{"auth":"%s"}}}\n' "$secret" > "$H/.docker/config.json"
out="$(run_installer --diff --only docker 2>&1)"; rc=$?
assert_rc "--diff exits 4 on an edited docker copy" 4 "$rc"
if [[ "$out" == *"$secret"* ]]; then err "--diff printed the docker auth value"; else ok "--diff never prints the docker auth value"; fi
assert_contains "--diff marks the value redacted" "$out" "<redacted>"
rm "$H/.docker/config.json"
run_installer --only docker >/dev/null 2>&1 || err "could not restore the docker copy after the --diff check"

# A link whose text starts with this folder's path but climbs out with `..`
# is not ours: --diff names it and never reads the file it leads to.
printf 'outside-marker-line\n' > "$T/outside.txt"
rm "$H/.config/starship.toml"
# Enough `..` to reach / from the physical config dir, so the marker really
# exists at the end of the link (a short climb would dangle and pass anyway).
up=""; walk="$D/config"
while [[ "$walk" != "/" && -n "$walk" ]]; do up="$up/.."; walk="${walk%/*}"; done
trav="$D/config$up$T/outside.txt"
[[ "$(cat "$trav" 2>/dev/null)" == outside-marker-line ]] || err "traversing link does not reach the marker"
ln -s "$trav" "$H/.config/starship.toml"
out="$(run_installer --diff --only starship 2>&1)"; rc=$?
assert_rc "--diff exits 4 on a traversing link" 4 "$rc"
assert_contains "--diff reports a traversing link as CONFLICT" "$out" "CONFLICT $H/.config/starship.toml"
assert_contains "--diff names where a traversing link leads" "$out" "  links to $trav"
if [[ "$out" == *outside-marker-line* ]]; then err "--diff read the file a traversing link leads to"; else ok "--diff never reads the file a traversing link leads to"; fi
# Even one that would land back on a tracked file is refused: a `..` segment
# is never ours.
rm "$H/.config/starship.toml"
ln -s "$D/config/../config/starship.toml" "$H/.config/starship.toml"
out="$(run_installer --diff --only starship 2>&1)"
assert_contains "a link with a .. segment is not ours" "$out" "  links to $D/config/../config/starship.toml"
rm "$H/.config/starship.toml"
run_installer --only starship >/dev/null 2>&1 || err "could not relink starship.toml after the traversal check"

# The final component counts too: an alias inside this folder that is itself
# a link to a file outside leads out, whatever directory it sits in. Built in
# a scratch copy of the installer so the repository tree is never written to.
M="$(cd -P "$scratch" && pwd -P)/mirror"
MH="$(cd -P "$scratch" && pwd -P)/mirror-home"
mkdir -p "$M/config" "$M/home" "$MH/.config"
cp "$SCRIPT" "$M/install_dotfiles.sh"
printf 'format = "src"\n' > "$M/config/starship.toml"
ln -s "$T/outside.txt" "$M/config/alias"
mirror_installer() { HOME="$MH" TMPDIR="$T" env -u XDG_CONFIG_HOME "$M/install_dotfiles.sh" --home "$MH" "$@"; }
ln -s "$M/config/alias" "$MH/.config/starship.toml"
out="$(mirror_installer --diff --only starship 2>&1)"; rc=$?
assert_rc "--diff exits 4 on an alias link to an outside file" 4 "$rc"
assert_contains "--diff reports the alias link as CONFLICT" "$out" "CONFLICT $MH/.config/starship.toml"
if [[ "$out" == *outside-marker-line* ]]; then err "--diff printed the file an in-repo alias leads to"; else ok "--diff never prints the file an in-repo alias leads to"; fi
# A chain of two in-repo links that ends inside the folder is still ours.
rm "$MH/.config/starship.toml"
ln -s starship.toml "$M/config/hop1"
ln -s "$M/config/hop1" "$M/config/hop2"
ln -s "$M/config/hop2" "$MH/.config/starship.toml"
out="$(mirror_installer --status --only starship 2>&1)"
assert_contains "a chain of in-repo links is FOREIGN, not CONFLICT" "$out" "FOREIGN $MH/.config/starship.toml"
# A loop is treated as outside rather than followed forever.
rm "$MH/.config/starship.toml"
ln -s loop2 "$M/config/loop1"
ln -s loop1 "$M/config/loop2"
ln -s "$M/config/loop1" "$MH/.config/starship.toml"
out="$(mirror_installer --status --only starship 2>&1)"
assert_contains "a link loop is CONFLICT" "$out" "CONFLICT $MH/.config/starship.toml"
rm -rf "$M" "$MH"

run_installer --diff --dry-run >/dev/null 2>&1; rc=$?
assert_rc "--diff --dry-run exits 3" 3 "$rc"
run_installer --diff --force >/dev/null 2>&1; rc=$?
assert_rc "--diff --force exits 3" 3 "$rc"
run_installer --diff --status >/dev/null 2>&1; rc=$?
assert_rc "--diff --status exits 3" 3 "$rc"
out="$(guard "$SCRIPT" --help 2>&1)"
assert_contains "--help documents --diff" "$out" "--diff"

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
head_ "--installed-only"
# What counts as installed is decided by PATH alone, so this section owns its
# PATH: a directory of links to the utilities the installer calls plus stub
# commands for the tools it should see, and the installer started through
# $BASH so env needs no PATH lookup of its own.
IH="$scratch/home-installed"
mkdir -p "$IH"
make_bin() {
  local dir="$1" u p
  shift
  mkdir -p "$dir"
  for u in basename cat cmp chmod cp date diff dirname find grep ln ls mkdir mv readlink rm sed sort stat tr; do
    p="$(command -v "$u" || true)"
    [[ -n "$p" && "$p" == /* ]] && ln -s "$p" "$dir/$u"
  done
  # rm first: a stub must never be written through a link to a real binary.
  for u in "$@"; do
    rm -f "$dir/$u"
    printf '#!/bin/sh\nexit 0\n' > "$dir/$u"
    chmod +x "$dir/$u"
  done
}
run_with_path() {
  local path="$1"; shift
  guard env -u XDG_CONFIG_HOME HOME="$IH" TMPDIR="$T" PATH="$path" "$BASH" "$SCRIPT" --home "$IH" "$@"
}
make_bin "$scratch/bin-k9s-rg" k9s rg
make_bin "$scratch/bin-batcat" batcat
make_bin "$scratch/bin-none"

out="$(run_with_path "$scratch/bin-k9s-rg" --list --installed-only 2>&1)"; rc=$?
assert_rc "--list --installed-only exits 0" 0 "$rc"
got="$(list_units "$out")"
if [[ "$got" == "k9s ripgrep " ]]; then ok "--installed-only selects exactly the units whose tool is on PATH"; else err "--installed-only selected '$got', expected 'k9s ripgrep '"; fi

before="$(snapshot "$IH" "$T")"
out="$(run_with_path "$scratch/bin-k9s-rg" --dry-run --installed-only 2>&1)"; rc=$?
after="$(snapshot "$IH" "$T")"
assert_rc "--dry-run --installed-only exits 0" 0 "$rc"
assert_contains "--dry-run --installed-only previews ripgrep" "$out" "(dry-run) ln -s $D/config/ripgrep/config"
assert_contains "--dry-run --installed-only closes with the summary line" "$out" "dry-run complete; no changes written"
if [[ "$out" == *starship* ]]; then err "--installed-only previewed a tool that is not on PATH"; else ok "--installed-only previews nothing else"; fi
if [[ "$before" == "$after" ]]; then ok "--dry-run --installed-only wrote nothing"; else err "--dry-run --installed-only wrote into the home or tmp"; fi

out="$(run_with_path "$scratch/bin-k9s-rg" --installed-only 2>&1)"; rc=$?
assert_rc "install --installed-only exits 0" 0 "$rc"
assert_true "the k9s config was installed" test -e "$IH/.config/k9s/config.yaml"
assert_true "the ripgrep config was installed" test -L "$IH/.config/ripgrep/config"
assert_true "starship, not on PATH, was not installed" test ! -e "$IH/.config/starship.toml"
assert_true "ssh, not on PATH, was not installed" test ! -e "$IH/.ssh"
out="$(run_with_path "$scratch/bin-k9s-rg" --status --installed-only 2>&1)"; rc=$?
assert_rc "--status --installed-only reports no false MISSING" 0 "$rc"

# --prune --only UNIT --installed-only on a wholly deleted unit: the orphan
# links count as selected, so the tool being on PATH is enough (not exit 4).
make_bin "$scratch/bin-foo" foo
mkdir -p "$IH/.foo"
ln -s "$D/home/.foo/config" "$IH/.foo/config"
out="$(run_with_path "$scratch/bin-foo" --prune --only foo --installed-only --dry-run 2>&1)"; rc=$?
assert_rc "--prune --only <deleted unit> --installed-only exits 0" 0 "$rc"
assert_contains "--prune --only <deleted unit> --installed-only previews the rm" "$out" "(dry-run) rm $IH/.foo/config"
run_with_path "$scratch/bin-none" --prune --only foo --installed-only --dry-run >/dev/null 2>&1; rc=$?
assert_rc "--prune --only <deleted unit> --installed-only without its tool exits 4" 4 "$rc"
rm "$IH/.foo/config"; rmdir "$IH/.foo"

# --backups/--restore --only UNIT --installed-only on a wholly deleted unit:
# its stray backup counts as selected, so the tool being on PATH is enough.
make_bin "$scratch/bin-oldtool" oldtool
mkdir -p "$IH/.config/oldtool"
printf 'kept\n' > "$IH/.config/oldtool/x.backup-20200101-000000"
ln -s "$D/config/oldtool/x" "$IH/.config/oldtool/x"
out="$(run_with_path "$scratch/bin-oldtool" --backups --only oldtool --installed-only 2>&1)"; rc=$?
assert_rc "--backups --only <deleted unit> --installed-only exits 0" 0 "$rc"
assert_contains "--backups --only <deleted unit> --installed-only lists the backup" "$out" "x.backup-20200101-000000"
run_with_path "$scratch/bin-oldtool" --restore --dry-run --only oldtool --installed-only >/dev/null 2>&1; rc=$?
assert_rc "--restore --only <deleted unit> --installed-only exits 0" 0 "$rc"
run_with_path "$scratch/bin-none" --backups --only oldtool --installed-only >/dev/null 2>&1; rc=$?
assert_rc "--backups --only <deleted unit> --installed-only without its tool exits 4" 4 "$rc"
rm "$IH/.config/oldtool/x" "$IH/.config/oldtool/x.backup-20200101-000000"; rmdir "$IH/.config/oldtool"

out="$(run_with_path "$scratch/bin-batcat" --list --installed-only 2>&1)"; rc=$?
assert_rc "--installed-only finds bat as batcat" 0 "$rc"
assert_contains "batcat selects the bat unit" "$(list_units "$out")" "bat "
out="$(run_with_path "$scratch/bin-none" --list --installed-only 2>&1)"; rc=$?
assert_rc "no tool on PATH exits 4" 4 "$rc"
assert_contains "no tool on PATH is reported" "$out" "no selected unit has its tool on PATH"
run_with_path "$scratch/bin-none" --list --only kitty --installed-only >/dev/null 2>&1; rc=$?
assert_rc "--only kitty --installed-only without kitty exits 4, not 3" 4 "$rc"
run_with_path "$scratch/bin-none" --list --only nope --installed-only >/dev/null 2>&1; rc=$?
assert_rc "--only nope --installed-only exits 3" 3 "$rc"

# Every unit must be reachable: with a stub for every command the README
# table names, --installed-only has to select every file --list knows. A unit
# whose command is missing from the table, or that tool_of() maps to a name
# the table does not give, drops out and the count falls short.
# Every backticked word in the second column of that table, one per line.
# shellcheck disable=SC2016  # $0 is an awk field
readme_cmds_awk='
/^### Commands --installed-only looks for/ { on = 1; next }
on && /^#/ { on = 0 }
on && /^[|] `/ {
  split($0, cell, "|")
  s = cell[3]
  while (match(s, /`[^`]+`/)) { print substr(s, RSTART + 1, RLENGTH - 2); s = substr(s, RSTART + RLENGTH) }
}
'
readme_cmds=()
while IFS= read -r c; do
  [[ -n "$c" ]] && readme_cmds+=("$c")
done < <(awk "$readme_cmds_awk" "$D/README.md")
if (( ${#readme_cmds[@]} > 0 )); then
  ok "the README names ${#readme_cmds[@]} commands for --installed-only"
  make_bin "$scratch/bin-all" "${readme_cmds[@]}"
  out="$(run_with_path "$scratch/bin-all" --list --installed-only 2>&1)"; rc=$?
  assert_rc "--installed-only with every command on PATH exits 0" 0 "$rc"
  n_sel=0
  while read -r u _; do
    [[ -z "$u" || "$u" == "UNIT" ]] && continue
    n_sel=$((n_sel + 1))
  done <<< "$out"
  if [[ "$n_sel" == "$n_rows" ]]; then ok "every unit is selected through a command the README names"; else err "--installed-only selected $n_sel of $n_rows files with every README command on PATH"; fi
else
  err "the README has no 'Commands --installed-only looks for' table"
fi

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
  py_verdicts=0
  while IFS=$'\t' read -r verdict message; do
    case "$verdict" in
      ok)   ok "$message" ;;
      err)  err "$message" ;;
      skip) skip "$message" ;;
    esac
    py_verdicts=$(( py_verdicts + 1 ))
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
  # A process substitution's exit status is invisible to the shell, so an
  # interpreter that cannot start emits no lines, the loop body never runs and
  # every config passes by saying nothing. One verdict per file is the contract;
  # assert it rather than infer it from silence.
  if (( py_verdicts != ${#py_parse[@]} )); then
    err "the parse pass emitted $py_verdicts verdict(s) for ${#py_parse[@]} file(s) — $PY did not run them all"
  fi
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
