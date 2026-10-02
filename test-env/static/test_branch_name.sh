#!/usr/bin/env bash
# check_branch_name.sh, and the places that have to agree with it.
#
# What is asserted: the names it accepts and refuses, the title rule, the CLI
# contract; that every branch type is a pull_request target in each workflow
# that filters on target branches (a stacked pull request onto a type missing
# from a filter runs no checks and merges green); and that the branch names the
# bot workflows build for themselves pass the same check their pull requests
# will meet in CI.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/../.." && pwd)}"
CHECK="$HERE/check_branch_name.sh"

failures=0
checks=0
ok()  { printf '[ ok ] %s\n' "$*"; checks=$((checks + 1)); }
err() { printf '[fail] %s\n' "$*" >&2; failures=$((failures + 1)); checks=$((checks + 1)); }

# expect WANT_RC NAME -- ARGS...
expect() {
  local want="$1" name="$2"; shift 3
  "$CHECK" "$@" >/dev/null 2>&1
  local rc=$?
  if [[ "$rc" -eq "$want" ]]; then ok "$name (exit $rc)"; else err "$name: exit $rc, want $want"; fi
}

if [[ ! -x "$CHECK" ]]; then
  err "$CHECK is missing or not executable"
  exit 1
fi

# --- accepted --------------------------------------------------------------
for b in feat/release-workflow fix/routeros-record-hash-hardening docs/readme \
         ci/branch-naming test/suite-floors perf/faster-scan refactor/split-parser \
         deps/routeros-7.24.6 release/1.0.0 release/10.20.30 \
         feat/macos/stay-fresh dependabot/docker/test-env/go/docker/docker-052b39166c \
         refs/heads/fix/x; do
  expect 0 "accepts $b" -- "$b"
done

# --- refused ---------------------------------------------------------------
for b in chore/routeros-7.24.6 chore/release-1.0.0 claude/pr-review-feedback-j9q5qi \
         ai/x copilot/x feature/old-prefix wip/x master readme-fix \
         fix/Upper-Case fix/space\ here fix/ fix//double release/1.0 release/v1.0.0 \
         release/1.0.0-rc.1; do
  expect 1 "refuses '$b'" -- "$b"
done

out="$("$CHECK" chore/x 2>&1)"
if [[ "$out" == *"deps/"* && "$out" == *"release/"* ]]; then
  ok "the chore/ refusal names what to use instead"
else
  err "the chore/ refusal does not name deps/ and release/: $out"
fi
out="$("$CHECK" claude/x 2>&1)"
if [[ "$out" == *"named after a tool"* ]]; then
  ok "a tool prefix gets its own message"
else
  err "tool prefix message: $out"
fi

# --- titles ----------------------------------------------------------------
expect 0 "a deps title passes"               -- --title "deps(mikrotik): test against RouterOS 7.24.6" deps/routeros-7.24.6
expect 0 "a free-form title passes"          -- --title "Four doctors and a lint suite" feat/x
expect 0 "a title mentioning chores passes"  -- --title "fix(wsl): the chores it automates" fix/x
expect 1 "a chore: title is refused"         -- --title "chore: bump golang" deps/golang
expect 1 "a chore(scope): title is refused"  -- --title "chore(mikrotik): test against RouterOS 7.24.6" deps/routeros-7.24.6
expect 1 "a Chore! title is refused"         -- --title "Chore!: breaking" fix/x
expect 1 "a good branch with a chore title fails" -- --title=chore:\ x fix/x

# --- CLI contract ----------------------------------------------------------
expect 0 "--help exits 0"            -- --help
expect 3 "an unknown flag exits 3"   -- --definitely-not-a-flag
expect 3 "no BRANCH exits 3"         --
expect 3 "--title without a value"   -- --title
expect 3 "two branches exit 3"       -- fix/a fix/b
types="$("$CHECK" --list-types)"
if [[ -n "$types" && "$types" != *chore* ]]; then
  ok "--list-types prints the types, without chore"
else
  err "--list-types: '$types'"
fi

# --- workflow target filters ---------------------------------------------------
# Every type must be a pull_request target wherever targets are filtered, and
# chore/ must be gone from all of them.
for wf in ci.yml chr.yml security.yml; do
  f="$REPO_ROOT/.github/workflows/$wf"
  # The pull_request block's branches list: from "pull_request:" to the next
  # top-level-under-on key, quoted patterns only.
  targets="$(awk '
    /^  pull_request:/ { s = 1; next }
    s && /^  [a-z_]+:/  { exit }
    s && /^      - / { gsub(/[ \x27"-]/, ""); print }
  ' "$f")"
  if [[ -z "$targets" ]]; then
    err "$wf: found no pull_request branch filter to check"
    continue
  fi
  missing=""
  for t in $types; do
    grep -qx "$t/\*\*" <<< "$targets" || missing="$missing $t/"
  done
  if [[ -n "$missing" ]]; then
    err "$wf: pull_request targets miss:$missing"
  else
    ok "$wf: every branch type is a pull_request target"
  fi
  if grep -q '^chore/' <<< "$targets"; then
    err "$wf: still targets chore/**"
  else
    ok "$wf: no chore/ target"
  fi
done

# --- branch names the bots build -------------------------------------------
# Each assignment is rendered with a sample version and run through the same
# check the pull request meets in CI.
render() { # FILE VAR SAMPLE
  grep -E '^ *branch="[^"]*"$' "$REPO_ROOT/.github/workflows/$1" \
    | head -n 1 | sed -E 's/^ *branch="(.*)"$/\1/' \
    | sed -e "s/\${$2}/$3/" -e "s/\$$2/$3/"
}
for spec in "routeros-version.yml TARGET_VERSION 7.24.6" "release.yml VERSION 1.0.0"; do
  read -r wf_file var sample <<< "$spec"
  set -- "$wf_file" "$var" "$sample"
  name="$(render "$1" "$2" "$3")"
  if [[ -z "$name" ]]; then
    err "$1: found no branch=\"...\" assignment to check"
  elif "$CHECK" "$name" >/dev/null 2>&1; then
    ok "$1 builds a conforming branch ($name)"
  else
    err "$1 builds '$name', which check_branch_name.sh refuses"
  fi
done
# The titles those workflows give their pull requests and commits.
for wf in routeros-version.yml release.yml; do
  if grep -nE -- '(--title|git commit -m) "chore' "$REPO_ROOT/.github/workflows/$wf" >/dev/null; then
    err "$wf still writes a chore title or commit subject"
  else
    ok "$wf writes no chore title or commit subject"
  fi
done
if grep -nE '^ *prefix: *chore' "$REPO_ROOT/.github/dependabot.yml" >/dev/null; then
  err ".github/dependabot.yml still gives Dependabot a chore commit prefix"
else
  ok ".github/dependabot.yml gives Dependabot no chore commit prefix"
fi

printf '\n'
if (( failures > 0 )); then
  printf '=== %s of %s branch-name check(s) failed ===\n' "$failures" "$checks" >&2
  exit 1
fi
printf '=== all %s branch-name checks passed ===\n' "$checks"
