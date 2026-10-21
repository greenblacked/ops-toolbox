#!/usr/bin/env bash
# Verify git_release_notes.sh groups commits since a tag by type, leaves merges
# out, and suggests the next version, in disposable repositories.

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
RELEASE_NOTES="$REPO_ROOT/git/git_release_notes.sh"
scratch="$(mktemp -d /tmp/release-notes-tests.XXXXXX)"
if [[ -z "$scratch" || ! -d "$scratch" ]]; then
  printf 'cannot create test scratch directory\n' >&2
  exit 1
fi
trap 'rm -rf "$scratch"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
checks=0
failures=0
section_checks=0
section_name=""
ok() { checks=$((checks + 1)); section_checks=$((section_checks + 1)); printf '[ ok ] %s\n' "$*"; }
err() { checks=$((checks + 1)); section_checks=$((section_checks + 1)); failures=$((failures + 1)); printf '[fail] %s\n' "$*" >&2; }
# A section that asserted nothing is a failure: its fixture never reached an
# assertion, which reads as a pass without this.
section() {
  end_section
  section_name="$1"
  section_checks=0
}
end_section() {
  [[ -n "$section_name" ]] || return 0
  if (( section_checks == 0 )); then
    err "section '$section_name' made no assertion"
  fi
  section_name=""
}
assert_eq() {
  if [[ "$1" == "$2" ]]; then ok "$3"; else err "$3: expected '$2', got '$1'"; fi
}
assert_contains() {
  if [[ "$1" == *"$2"* ]]; then ok "$3"; else err "$3: missing '$2' in: $1"; fi
}
assert_not_contains() {
  if [[ "$1" != *"$2"* ]]; then ok "$3"; else err "$3: unexpected '$2' in: $1"; fi
}
# True when $2 appears before $3 in $1.
assert_before() {
  if [[ "$1" == *"$2"* && "${1%%"$3"*}" == *"$2"* ]]; then
    ok "$4"
  else
    err "$4: '$2' does not come before '$3' in: $1"
  fi
}
run_in() {
  local dir="$1"
  shift
  (cd "$dir" && "$RELEASE_NOTES" "$@")
}
# new_repo DIR TAG: a repository whose root commit carries TAG (none if empty).
new_repo() {
  git init -q -b main "$1" &&
    git -C "$1" config user.name Test &&
    git -C "$1" config user.email test@example.com &&
    git -C "$1" commit -q --allow-empty -m 'chore: initial' || return 1
  if [[ -n "$2" ]]; then
    git -C "$1" tag "$2" || return 1
  fi
}
commit() {
  git -C "$1" commit -q --allow-empty -m "$2"
}

# --- fixture ---------------------------------------------------------------
repo="$scratch/repo"
new_repo "$repo" v1.2.3 &&
  commit "$repo" 'feat(api): add health endpoint' || { err 'create fixture'; exit 1; }
api_sha="$(git -C "$repo" rev-parse --short HEAD)"
commit "$repo" 'fix: handle empty list' &&
  commit "$repo" 'perf(core): cache lookups' &&
  commit "$repo" 'docs: update readme' &&
  commit "$repo" 'ci: pin runner' &&
  commit "$repo" 'chore: tidy' &&
  commit "$repo" 'wip stuff' &&
  commit "$repo" 'refactor!: drop legacy flag' &&
  printf 'feat: rename config\n\nBREAKING CHANGE: config renamed\n' |
    git -C "$repo" commit -q --allow-empty -F - &&
  git -C "$repo" switch -q -c side &&
  commit "$repo" 'test: side work' &&
  git -C "$repo" switch -q main &&
  git -C "$repo" merge -q --no-ff -m 'Merge branch side' side || { err 'create commit fixture'; exit 1; }

section "text notes"
out="$(run_in "$repo" 2>&1)"; rc=$?
assert_eq "$rc" 0 'notes since the last tag -> 0'
assert_contains "$out" 'v1.2.3..HEAD' 'the notes are headed with the range'
assert_before "$out" 'Breaking changes' 'Features' 'breaking changes come before features'
assert_before "$out" 'Features' 'Fixes' 'features come before fixes'
assert_before "$out" 'Fixes' 'Performance' 'fixes come before performance'
assert_before "$out" 'Documentation' 'Build and CI' 'documentation comes before build and CI'
assert_before "$out" 'Build and CI' 'Other' 'build and CI come before other'
assert_contains "$out" "  - api: add health endpoint ($api_sha)" 'a scoped entry carries scope, description and short sha'
assert_contains "$out" '  - handle empty list (' 'an unscoped entry carries the description'
assert_contains "${out#*Other}" 'wip stuff' 'a subject that is not conventional lands under Other'
assert_contains "${out%%Features*}" 'drop legacy flag' 'a ! marks a breaking change'
assert_contains "${out%%Features*}" 'rename config' 'a BREAKING CHANGE body line marks a breaking change'
assert_contains "${out#*Other}" 'side work' 'a commit merged from a side branch is listed'
assert_not_contains "$out" 'Merge branch side' 'the merge commit is left out'
assert_not_contains "$out" 'initial' 'the tagged commit itself is not in the range'

section "markdown"
out="$(run_in "$repo" --format markdown 2>&1)"
assert_contains "$out" '## v1.2.3..HEAD' 'markdown opens with a level-two heading'
assert_contains "$out" '### Features' 'markdown sections are level-three headings'
assert_contains "$out" "- api: add health endpoint ($api_sha)" 'markdown bullets are plain dashes'
out="$(run_in "$repo" --format=markdown 2>&1)"
assert_contains "$out" '### Fixes' '--format=markdown equals form is accepted'
run_in "$repo" --format html >/dev/null 2>&1; rc=$?
assert_eq "$rc" 3 'an unknown --format -> 3'

section "next version"
out="$(run_in "$repo" --next-version 2>&1)"; rc=$?
assert_eq "$rc" 0 '--next-version -> 0'
assert_eq "$out" '2.0.0' 'a breaking change bumps the major version and prints nothing else'
feat_repo="$scratch/feat"
new_repo "$feat_repo" v1.2.3 &&
  commit "$feat_repo" 'feat: a feature' &&
  commit "$feat_repo" 'fix: a fix' || err 'create feat fixture'
assert_eq "$(run_in "$feat_repo" --next-version 2>&1)" '1.3.0' 'a feature bumps the minor version'
fix_repo="$scratch/fix"
new_repo "$fix_repo" v1.2.3 &&
  commit "$fix_repo" 'fix: a fix' &&
  commit "$fix_repo" 'docs: a doc' || err 'create fix fixture'
assert_eq "$(run_in "$fix_repo" --next-version 2>&1)" '1.2.4' 'fixes and docs bump the patch version'

section "a tag on --to describes that release"
git -C "$feat_repo" tag -a v1.3.0 -m 'v1.3.0' || err 'tag the feat fixture'
out="$(run_in "$feat_repo" --to v1.3.0 --format markdown 2>&1)"; rc=$?
assert_eq "$rc" 0 '--to a tag -> 0'
assert_contains "$out" '## v1.3.0 (' 'a tag on --to heads the notes with its name and date'
assert_contains "$out" 'a feature' 'the notes run from the previous tag, not from v1.3.0 itself'

section "ranges and tags"
out="$(run_in "$repo" --from v1.2.3 --to HEAD~3 2>&1)"
assert_contains "$out" 'add health endpoint' 'an explicit range includes its first commit'
assert_not_contains "$out" 'drop legacy flag' 'an explicit range stops at --to'
rel_repo="$scratch/release"
new_repo "$rel_repo" release-1 &&
  commit "$rel_repo" 'feat: after release' || err 'create release-tag fixture'
out="$(run_in "$rel_repo" --match 'release-*' 2>&1)"
assert_contains "$out" 'release-1..HEAD' '--match finds a tag outside the default pattern'
run_in "$rel_repo" --match 'release-*' --next-version >/dev/null 2>&1; rc=$?
assert_eq "$rc" 3 '--next-version from a tag that is not semver -> 3'
none_repo="$scratch/none"
new_repo "$none_repo" "" &&
  commit "$none_repo" 'feat: something' || err 'create untagged fixture'
out="$(run_in "$none_repo" 2>&1)"; rc=$?
assert_eq "$rc" 0 'a repository with no tag still gets notes'
assert_contains "$out" 'using the whole history' 'no matching tag says the whole history is used'
assert_contains "$out" 'something' 'the whole history is listed'
run_in "$none_repo" --next-version >/dev/null 2>&1; rc=$?
assert_eq "$rc" 3 '--next-version with no tag -> 3'

section "bad refs and usage"
run_in "$repo" --from nope >/dev/null 2>&1; rc=$?
assert_eq "$rc" 3 'an unknown --from -> 3'
run_in "$repo" --from HEAD --to HEAD >/dev/null 2>&1; rc=$?
assert_eq "$rc" 4 'an empty range -> 4'
run_in "$repo" --from >/dev/null 2>&1; rc=$?
assert_eq "$rc" 3 '--from without a value -> 3'
run_in "$repo" --definitely-not-a-flag >/dev/null 2>&1; rc=$?
assert_eq "$rc" 3 'unknown flag -> 3'
out="$(run_in "$repo" --help 2>&1)"
assert_not_contains "$out" '--dry-run' 'a read-only report does not advertise a dry run'
mkdir -p "$scratch/plain" || err 'create plain directory'
(cd "$scratch/plain" && GIT_CEILING_DIRECTORIES="$scratch" "$RELEASE_NOTES") >/dev/null 2>&1; rc=$?
assert_eq "$rc" 2 'outside a repository -> 2'
refs_before="$(git -C "$repo" for-each-ref)"
run_in "$repo" --format markdown >/dev/null 2>&1
assert_eq "$(git -C "$repo" for-each-ref)" "$refs_before" 'no tag or ref is created'

end_section
if (( checks == 0 || failures > 0 )); then
  printf '=== %s of %s release notes checks failed ===\n' "$failures" "$checks" >&2
  exit 1
fi
printf '=== all %s release notes checks passed ===\n' "$checks"
