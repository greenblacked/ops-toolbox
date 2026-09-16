#!/usr/bin/env bash
# Run, locally, exactly the linters the `Lint` job in .github/workflows/ci.yml
# runs: bash -n, ShellCheck (twice), actionlint, Hadolint, PSScriptAnalyzer,
# yamllint and markdownlint-cli2.
#
# It exists because those seven had no local entry point at all. `run-tests.sh`
# knew nine suites and not one of them ran a linter, so the only way to learn
# that a change tripped markdownlint was to push it — which is how a changelog
# fragment reached a pull request with an MD038 violation in it while
# `npx markdownlint-cli2` sat installed on the same machine.
#
# Parity is the whole point, so the invocations below are copies of the ones in
# ci.yml, flag for flag and glob for glob, and the versions come from the same
# two files CI reads rather than from whatever is on PATH. Where this suite
# deliberately differs from CI, it says so at the check.
#
# Options (environment):
#   LINT_FETCH=1           download the pinned ShellCheck/actionlint/Hadolint
#                          binaries when they are absent, verifying each against
#                          .github/ci-tool-checksums.env. Off by default: a test
#                          suite should not reach the network unasked.
#   LINT_ALLOW_UNPINNED=1  use a tool whose version differs from the pin, with a
#                          warning, instead of skipping it.
#   LINT_CACHE_DIR=PATH    where fetched binaries live.
#                          Default $XDG_CACHE_HOME/ops-toolbox-lint.
#   LINT_STRICT=1          treat any skipped linter as a failure. This is what
#                          CI sets: on a runner that just installed all six,
#                          a skip means an install step silently stopped
#                          working, and the job must not report success for it.
#   LINT_CHECKS=a,b,c      run only these checks. Names: shell (bash -n and both
#                          ShellCheck passes), workflow, dockerfile, powershell,
#                          yaml, markdown. Default: all of them. This exists for
#                          the Lint job, which knows from its change filters
#                          which ones a pull request needs; by hand, the default
#                          is the one you want. Unset or empty means all of
#                          them; a value that names nothing (`,`) is refused,
#                          because it is a selection, and it selected nothing.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
cd "$REPO_ROOT" || { echo "cannot enter $REPO_ROOT" >&2; exit 1; }

# Every one of these aims a linter from outside the repository, which is the
# one thing a gate must not allow: SHELLCHECK_OPTS can add --exclude, both
# yamllint variables replace .yamllint.yml, and the Hadolint block can lower or
# remove the failure threshold. Exported by a developer or inherited from a
# shell profile, each of them turns a green run into a run that checked less
# than it said. Same reasoning as the unset at the top of test-env/static/run.sh.
unset SHELLCHECK_OPTS
unset YAMLLINT_CONFIG_FILE YAMLLINT_CONFIG_DATA
unset HADOLINT_CONFIG HADOLINT_FORMAT HADOLINT_FAILURE_THRESHOLD
unset HADOLINT_NOFAIL HADOLINT_STRICT_LABELS HADOLINT_IGNORE
unset HADOLINT_OVERRIDE_ERROR HADOLINT_OVERRIDE_WARNING
unset HADOLINT_OVERRIDE_INFO HADOLINT_OVERRIDE_STYLE

CI_YML=".github/workflows/ci.yml"
SUMS_ENV=".github/ci-tool-checksums.env"
CACHE_DIR="${LINT_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/ops-toolbox-lint}"
FETCH="${LINT_FETCH:-0}"
ALLOW_UNPINNED="${LINT_ALLOW_UNPINNED:-0}"
STRICT="${LINT_STRICT:-0}"

for f in "$CI_YML" "$SUMS_ENV"; do
  [[ -f "$f" ]] || { echo "$f is missing — the pins this suite mirrors are not readable" >&2; exit 1; }
done
command -v git >/dev/null 2>&1 || { echo "git is required; the file lists below read the index" >&2; exit 1; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "$REPO_ROOT is not a git working tree" >&2; exit 1; }

rc=0
# `ran` counts the six installable linters only. bash -n is deliberately not one
# of them: bash is always present, so counting it would leave this suite's floor
# permanently satisfied by a check that can never go missing — and a run that
# managed nothing but `bash -n` would report a clean lint. That is precisely the
# false verdict this suite was written to end, so it must not be the one it
# hands back.
ran=0
SKIPS=()

note_skip() { SKIPS+=("$1: $2"); printf 'skip  %s — %s\n' "$1" "$2"; }
fail()      { rc=1; printf 'FAIL  %s\n' "$1"; }
pass()      { printf 'ok    %s\n' "$1"; }

# --- which checks to run ----------------------------------------------------
ALL_CHECKS="shell workflow dockerfile powershell yaml markdown"
CHECKS="${LINT_CHECKS:-$ALL_CHECKS}"
CHECKS="${CHECKS//,/ }"
for c in $CHECKS; do
  case " $ALL_CHECKS " in
    *" $c "*) ;;
    *) echo "unknown check in LINT_CHECKS: $c (known: $ALL_CHECKS)" >&2; exit 3 ;;
  esac
done
# An empty selection is an error, not a fast clean run. The caller that passes
# one has decided nothing needs linting, and that decision belongs where it can
# be read — a step-level `if` in the workflow, or a suite you did not name —
# rather than here, where it would surface as a suite that passed having done
# nothing. The floor at the bottom would catch it, but this says why.
if [[ -z "${CHECKS// }" ]]; then
  echo "LINT_CHECKS is empty — refusing to report a clean lint having selected no check" >&2
  exit 3
fi
want() {
  case " $CHECKS " in
    *" $1 "*) return 0 ;;
    *) printf -- '-     %s — not selected (LINT_CHECKS=%s)\n' "$1" "${LINT_CHECKS:-}"; return 1 ;;
  esac
}

# --- the pins ---------------------------------------------------------------
# Versions: .github/ci-tool-checksums.env where it records one, the top-level
# env: block of ci.yml otherwise. The two are not interchangeable and the split
# is not arbitrary — yamllint, PSScriptAnalyzer and markdownlint arrive through
# package managers that verify their own downloads, so that file deliberately
# carries no entry for them (its NO_DIGEST_TOOLS line says so) and ci.yml is
# where their version lives. check_conventions.sh asserts the two files agree
# for every tool that is in both, so reading either is reading the same pin.
#
# Digests: that file only, which is what CONTRIBUTING and its own header mean
# by source of truth.
pin() {
  local tool="$1" v
  v="$(awk -F= -v k="${tool}_VERSION" '$1 == k { print $2 }' "$SUMS_ENV" | tr -d "\"'")"
  if [[ -z "$v" ]]; then
    v="$(awk -v k="${tool}_VERSION:" '
      /^env:[[:space:]]*$/       { in_env = 1; next }
      in_env && /^[^[:space:]#]/ { in_env = 0 }
      in_env && $1 == k          { print $2 }
    ' "$CI_YML" | tr -d "\"'")"
  fi
  printf '%s\n' "$v"
}

digest() { awk -F= -v k="$1" '$1 == k { print $2 }' "$SUMS_ENV" | tr -d "\"'"; }

# A pin that reads back empty means one of the two files was renamed,
# reindented or emptied. That is a failure, not a skip: carrying on would lint
# with whatever is installed, which is the state this suite exists to end.
require_pin() {
  local tool="$1" v
  v="$(pin "$tool")"
  if [[ -z "$v" ]]; then
    echo "no ${tool}_VERSION in $SUMS_ENV or the env: block of $CI_YML — the pin this suite mirrors is gone" >&2
    exit 1
  fi
  printf '%s\n' "$v"
}

SHELLCHECK_VERSION="$(require_pin SHELLCHECK)" || exit 1
ACTIONLINT_VERSION="$(require_pin ACTIONLINT)" || exit 1
HADOLINT_VERSION="$(require_pin HADOLINT)" || exit 1
YAMLLINT_VERSION="$(require_pin YAMLLINT)" || exit 1
PSSA_VERSION="$(require_pin PSSA)" || exit 1
# markdownlint is the one tool ci.yml pins by action SHA rather than by version.
# See the report accompanying this suite: until ci.yml carries the version, this
# falls back to the version bundled by the pinned markdownlint-cli2-action.
MARKDOWNLINT_VERSION="$(pin MARKDOWNLINT)"
[[ -n "$MARKDOWNLINT_VERSION" ]] || MARKDOWNLINT_VERSION=0.23.2

printf 'pins: shellcheck %s  actionlint %s  hadolint %s  yamllint %s  pssa %s  markdownlint-cli2 %s\n' \
  "$SHELLCHECK_VERSION" "$ACTIONLINT_VERSION" "$HADOLINT_VERSION" \
  "$YAMLLINT_VERSION" "$PSSA_VERSION" "$MARKDOWNLINT_VERSION"

# --- obtaining a pinned binary ---------------------------------------------
os_arch() {
  local s m
  s="$(uname -s)"; m="$(uname -m)"
  case "$s:$m" in
    Linux:x86_64)   printf 'LINUX_AMD64\n' ;;
    Darwin:arm64)   printf 'DARWIN_ARM64\n' ;;
    Darwin:x86_64)  printf 'DARWIN_AMD64\n' ;;
    *)              printf '%s\n' "UNSUPPORTED_${s}_${m}" ;;
  esac
}
PLATFORM="$(os_arch)"

# Verify a download against the recorded digest before anything unpacks or runs
# it, exactly as each install step in ci.yml does. sha256sum on Linux, shasum on
# macOS, which is the same split ci.yml's macos-native job makes.
verify_sha256() {
  local file="$1" want="$2"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c - <<<"$want  $file" >/dev/null
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -c - <<<"$want  $file" >/dev/null
  else
    echo "neither sha256sum nor shasum is available; refusing to install an unverified binary" >&2
    return 1
  fi
}

fetch_verified() {
  local url="$1" out="$2" want="$3"
  curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors \
    --retry-connrefused --connect-timeout 10 "$url" -o "$out" || return 1
  if ! verify_sha256 "$out" "$want"; then
    rm -f "$out"
    echo "digest mismatch for $url — the asset behind the pinned URL is not the one $SUMS_ENV vetted" >&2
    return 1
  fi
}

# markdownlint-cli2 has no --version flag. Its banner, "markdownlint-cli2 vX.Y.Z
# (markdownlint ...)", is the first line of every run including --help, which
# exits 2 without touching a file — so that is the probe, and the status is
# dropped on purpose.
markdownlint_version() {
  { "$@" --help 2>&1 || true; } | awk 'NR == 1 && $1 == "markdownlint-cli2" { sub(/^v/, "", $2); print $2 }'
}

tool_version() {
  case "$1" in
    shellcheck) "$2" --version 2>/dev/null | awk '/^version:/ { print $2 }' ;;
    actionlint) "$2" -version 2>/dev/null | head -n 1 ;;
    hadolint)   "$2" --version 2>/dev/null | awk '{ print $NF }' ;;
  esac
}

fetch_tool() {
  local tool="$1" want="$2" dest="$3" tmp key asset upper
  upper="$(printf '%s' "$tool" | tr '[:lower:]' '[:upper:]')"
  key="$(digest "${upper}_SHA256_${PLATFORM}")"
  if [[ -z "$key" ]]; then
    echo "no ${tool} digest recorded for $PLATFORM in $SUMS_ENV" >&2
    return 1
  fi
  tmp="$(mktemp -d)" || return 1
  mkdir -p "${dest%/*}" || { rm -rf "$tmp"; return 1; }
  case "$tool" in
    shellcheck)
      case "$PLATFORM" in
        LINUX_AMD64)  asset="shellcheck-v${want}.linux.x86_64.tar.xz" ;;
        DARWIN_ARM64) asset="shellcheck-v${want}.darwin.aarch64.tar.xz" ;;
        DARWIN_AMD64) asset="shellcheck-v${want}.darwin.x86_64.tar.xz" ;;
        *)            rm -rf "$tmp"; return 1 ;;
      esac
      fetch_verified \
        "https://github.com/koalaman/shellcheck/releases/download/v${want}/${asset}" \
        "$tmp/a.tar.xz" "$key" || { rm -rf "$tmp"; return 1; }
      tar -xJf "$tmp/a.tar.xz" -C "$tmp" || { rm -rf "$tmp"; return 1; }
      install -m 0755 "$tmp/shellcheck-v${want}/shellcheck" "$dest" || { rm -rf "$tmp"; return 1; }
      ;;
    actionlint)
      fetch_verified \
        "https://github.com/rhysd/actionlint/releases/download/v${want}/actionlint_${want}_linux_amd64.tar.gz" \
        "$tmp/a.tar.gz" "$key" || { rm -rf "$tmp"; return 1; }
      tar -xzf "$tmp/a.tar.gz" -C "$tmp" actionlint || { rm -rf "$tmp"; return 1; }
      install -m 0755 "$tmp/actionlint" "$dest" || { rm -rf "$tmp"; return 1; }
      ;;
    hadolint)
      fetch_verified \
        "https://github.com/hadolint/hadolint/releases/download/v${want}/hadolint-linux-x86_64" \
        "$tmp/hadolint" "$key" || { rm -rf "$tmp"; return 1; }
      install -m 0755 "$tmp/hadolint" "$dest" || { rm -rf "$tmp"; return 1; }
      ;;
  esac
  rm -rf "$tmp"
  printf 'fetched %s %s (digest verified against %s)\n' "$tool" "$want" "$SUMS_ENV" >&2
}

# resolve TOOL WANTED_VERSION — print a usable path, or nothing and return 1.
# Order: a matching binary already on PATH, then one previously fetched into the
# cache, then a fresh download when LINT_FETCH=1.
resolve() {
  local tool="$1" want="$2" cached found got
  cached="$CACHE_DIR/$tool-$want/$tool"

  found="$(command -v "$tool" 2>/dev/null)"
  if [[ -n "$found" ]]; then
    got="$(tool_version "$tool" "$found")"
    if [[ "$got" == "$want" ]]; then
      printf '%s\n' "$found"; return 0
    fi
    if [[ "$ALLOW_UNPINNED" == "1" ]]; then
      printf 'warning: %s on PATH is %s, the pin is %s — running it anyway (LINT_ALLOW_UNPINNED=1)\n' \
        "$tool" "${got:-unknown}" "$want" >&2
      printf '%s\n' "$found"; return 0
    fi
  fi

  if [[ -x "$cached" ]]; then printf '%s\n' "$cached"; return 0; fi
  [[ "$FETCH" == "1" ]] || return 1
  fetch_tool "$tool" "$want" "$cached" || return 1
  printf '%s\n' "$cached"
}

missing_reason() {
  local tool="$1" want="$2" found got
  found="$(command -v "$tool" 2>/dev/null)"
  if [[ -n "$found" ]]; then
    got="$(tool_version "$tool" "$found")"
    printf '%s on PATH is %s, the pin is %s; a different version is a different gate. Re-run with LINT_ALLOW_UNPINNED=1 to use it, or LINT_FETCH=1 to download the pinned build.' \
      "$tool" "${got:-an unreadable version}" "$want"
  else
    printf '%s is not installed. Re-run with LINT_FETCH=1 to download %s %s and verify it against %s.' \
      "$tool" "$tool" "$want" "$SUMS_ENV"
  fi
}

# --- the Bash source list ---------------------------------------------------
# ci.yml lines 318-346, copied: the same glob, the same six Git Bash dotfiles by
# name, and the same assertion that every one of them is still in the list. A
# silently shrinking file list is a silently weakening gate.
BASH_SOURCES=()
collect_ok=0
if want shell; then
DOTFILES=(
  windows/git-bash/.bashrc
  windows/git-bash/.bash_profile
  windows/git-bash/.aliases
  windows/git-bash/default-git-bash/.bashrc
  windows/git-bash/default-git-bash/.bash_profile
  windows/git-bash/default-git-bash/.aliases
)
while IFS= read -r -d '' f; do BASH_SOURCES+=("$f"); done \
  < <(git ls-files -z '*.sh' "${DOTFILES[@]}")

collect_ok=1
for dot in "${DOTFILES[@]}"; do
  found=0
  for got in ${BASH_SOURCES[@]+"${BASH_SOURCES[@]}"}; do
    [[ "$got" == "$dot" ]] && { found=1; break; }
  done
  if (( ! found )); then
    printf '%s is not in the ShellCheck file list — it was renamed, moved or deleted, and the linter would silently stop covering it\n' "$dot" >&2
    collect_ok=0
  fi
done
if (( ${#BASH_SOURCES[@]} == 0 )); then
  printf 'the Bash source list is empty — the glob matched nothing, so bash -n and ShellCheck would both pass having read no file\n' >&2
  collect_ok=0
fi
(( collect_ok )) || rc=1
printf 'collected %d bash sources (%d of them dotfiles)\n' "${#BASH_SOURCES[@]}" "${#DOTFILES[@]}"

# --- bash -n --------------------------------------------------------------
printf '\n--- bash -n ---\n'
if (( collect_ok )); then
  if bash -n "${BASH_SOURCES[@]}"; then
    pass "bash -n over ${#BASH_SOURCES[@]} scripts"
  else
    fail "bash -n"
  fi
else
  note_skip "bash -n" "the Bash source list could not be built"
fi

# --- ShellCheck -----------------------------------------------------------
printf '\n--- shellcheck ---\n'
if (( ! collect_ok )); then
  note_skip "shellcheck" "the Bash source list could not be built"
elif SHELLCHECK_BIN="$(resolve shellcheck "$SHELLCHECK_VERSION")"; then
  ran=$((ran + 1))
  # ci.yml lines 436 and 451. -x follows source directives; --shell=bash is
  # required for the dotfiles, which have no shebang.
  if "$SHELLCHECK_BIN" --severity=error -x --shell=bash "${BASH_SOURCES[@]}"; then
    pass "shellcheck --severity=error over ${#BASH_SOURCES[@]} scripts"
  else
    fail "shellcheck --severity=error"
  fi
  if "$SHELLCHECK_BIN" --include=SC2183 -x --shell=bash "${BASH_SOURCES[@]}"; then
    pass "shellcheck --include=SC2183 over ${#BASH_SOURCES[@]} scripts"
  else
    fail "shellcheck --include=SC2183 (printf argument counts)"
  fi
else
  note_skip "shellcheck" "$(missing_reason shellcheck "$SHELLCHECK_VERSION")"
fi
fi  # want shell

# --- actionlint -------------------------------------------------------------
if want workflow; then
printf '\n--- actionlint ---\n'
WORKFLOWS=()
while IFS= read -r -d '' f; do WORKFLOWS+=("$f"); done \
  < <(git ls-files -z '.github/workflows/*.yml' '.github/workflows/*.yaml')
if (( ${#WORKFLOWS[@]} == 0 )); then
  fail "actionlint: no tracked workflows under .github/workflows — a bare actionlint would exit 0 having read nothing"
elif ACTIONLINT_BIN="$(resolve actionlint "$ACTIONLINT_VERSION")"; then
  ran=$((ran + 1))
  # ci.yml line 484: bare `actionlint`, which finds the workflows itself and
  # reads .github/actionlint.yaml for the SC2016 exemption.
  if "$ACTIONLINT_BIN"; then
    pass "actionlint over ${#WORKFLOWS[@]} workflows"
  else
    fail "actionlint"
  fi
else
  note_skip "actionlint" "$(missing_reason actionlint "$ACTIONLINT_VERSION")"
fi
fi  # want workflow

# --- Hadolint ---------------------------------------------------------------
if want dockerfile; then
printf '\n--- hadolint ---\n'
DOCKERFILES=()
while IFS= read -r -d '' f; do
  [[ "${f##*/}" == Dockerfile ]] && DOCKERFILES+=("$f")
done < <(git ls-files -z)
if (( ${#DOCKERFILES[@]} == 0 )); then
  fail "hadolint: no tracked Dockerfiles were found"
elif HADOLINT_BIN="$(resolve hadolint "$HADOLINT_VERSION")"; then
  ran=$((ran + 1))
  # ci.yml line 535.
  if "$HADOLINT_BIN" --failure-threshold error "${DOCKERFILES[@]}"; then
    pass "hadolint over ${#DOCKERFILES[@]} Dockerfiles"
  else
    fail "hadolint"
  fi
else
  note_skip "hadolint" "$(missing_reason hadolint "$HADOLINT_VERSION")"
fi
fi  # want dockerfile

# --- PSScriptAnalyzer -------------------------------------------------------
if want powershell; then
printf '\n--- PSScriptAnalyzer ---\n'
PSFILES=()
while IFS= read -r -d '' f; do PSFILES+=("$f"); done \
  < <(git ls-files -z '*.ps1' '*.psm1')
if (( ${#PSFILES[@]} == 0 )); then
  # ci.yml line 564 exits 0 here. That is a zero-file pass, and this suite does
  # not copy it: a repository that has lost all its PowerShell is a finding.
  fail "PSScriptAnalyzer: no tracked *.ps1 or *.psm1 were found"
elif ! command -v pwsh >/dev/null 2>&1; then
  note_skip "PSScriptAnalyzer" "pwsh is not installed (brew install --cask powershell, or see windows/README.md)"
elif ! pwsh -NoProfile -Command "
    if (-not (Get-Module -ListAvailable PSScriptAnalyzer |
        Where-Object { \$_.Version.ToString() -eq '$PSSA_VERSION' })) { exit 1 }
  " >/dev/null 2>&1; then
  note_skip "PSScriptAnalyzer" \
    "module $PSSA_VERSION is not installed (pwsh -Command \"Install-Module PSScriptAnalyzer -RequiredVersion $PSSA_VERSION -Scope CurrentUser\")"
else
  ran=$((ran + 1))
  # ci.yml lines 562-573, including -RequiredVersion so a differently-versioned
  # copy fails loudly instead of silently changing the ruleset.
  if pwsh -NoProfile -Command "
      Import-Module PSScriptAnalyzer -RequiredVersion '$PSSA_VERSION' -ErrorAction Stop
      \$files = git ls-files '*.ps1' '*.psm1'
      if (-not \$files) { Write-Host 'no PowerShell files reached the analyser'; exit 1 }
      \$found = @()
      foreach (\$f in \$files) {
        \$found += Invoke-ScriptAnalyzer -Path \$f -Settings ./PSScriptAnalyzerSettings.psd1
      }
      if (\$found.Count) {
        \$found | Format-Table -AutoSize RuleName, Severity, ScriptName, Line, Message
        exit 1
      }
      Write-Host ('PSScriptAnalyzer clean over {0} files' -f \$files.Count)
    "; then
    pass "PSScriptAnalyzer over ${#PSFILES[@]} files"
  else
    fail "PSScriptAnalyzer"
  fi
fi
fi  # want powershell

# --- yamllint ---------------------------------------------------------------
if want yaml; then
printf '\n--- yamllint ---\n'
yamllint_ok=0
yamllint_got=""
if command -v yamllint >/dev/null 2>&1; then
  yamllint_got="$(yamllint --version 2>/dev/null)"
  if [[ "$yamllint_got" == "yamllint ${YAMLLINT_VERSION}" ]]; then
    yamllint_ok=1
  elif [[ "$ALLOW_UNPINNED" == "1" ]]; then
    printf 'warning: %s, the pin is yamllint %s — running it anyway (LINT_ALLOW_UNPINNED=1)\n' \
      "$yamllint_got" "$YAMLLINT_VERSION" >&2
    yamllint_ok=1
  fi
fi
if (( yamllint_ok )); then
  # The file list first, so a config change that narrows yaml-files to nothing
  # cannot pass as a clean run. `yamllint .` over zero files exits 0.
  yfiles="$(yamllint --config-file .yamllint.yml --list-files . | wc -l | tr -d ' ')"
  if [[ "$yfiles" == "0" ]]; then
    fail "yamllint: .yamllint.yml selected no files — a clean run over nothing"
  else
    ran=$((ran + 1))
    # ci.yml line 598.
    if yamllint --config-file .yamllint.yml .; then
      pass "yamllint over $yfiles files"
    else
      fail "yamllint"
    fi
  fi
elif [[ -n "$yamllint_got" ]]; then
  note_skip "yamllint" "$yamllint_got is installed, the pin is $YAMLLINT_VERSION; a different version is a different ruleset. pipx install 'yamllint==$YAMLLINT_VERSION', or re-run with LINT_ALLOW_UNPINNED=1."
else
  note_skip "yamllint" "yamllint is not installed (pipx install 'yamllint==$YAMLLINT_VERSION')"
fi
fi  # want yaml

# --- markdownlint -----------------------------------------------------------
if want markdown; then
printf '\n--- markdownlint ---\n'
MDFILES=()
while IFS= read -r -d '' f; do MDFILES+=("$f"); done < <(git ls-files -z '*.md')
if (( ${#MDFILES[@]} == 0 )); then
  fail "markdownlint: no tracked *.md were found"
else
  # Which markdownlint-cli2 to run, in the order resolve() uses for the release
  # binaries: a copy on PATH at the pinned version, then the copy npx already
  # has cached, then a download — and the download only under LINT_FETCH=1.
  # `npx --yes pkg@ver` asks the registry on every run whether or not the
  # package is cached, so a machine with no route to it hung for as long as
  # npm's retries last, which is the one thing a suite that promises no network
  # unasked must not do. --no-install fails at once instead, and is a skip.
  MD_CMD=()
  md_reason=""
  if command -v markdownlint-cli2 >/dev/null 2>&1; then
    md_got="$(markdownlint_version markdownlint-cli2)"
    if [[ "$md_got" == "$MARKDOWNLINT_VERSION" ]]; then
      MD_CMD=(markdownlint-cli2)
    elif [[ "$ALLOW_UNPINNED" == "1" ]]; then
      printf 'warning: markdownlint-cli2 on PATH is %s, the pin is %s — running it anyway (LINT_ALLOW_UNPINNED=1)\n' \
        "${md_got:-unknown}" "$MARKDOWNLINT_VERSION" >&2
      MD_CMD=(markdownlint-cli2)
    else
      md_reason="markdownlint-cli2 on PATH is ${md_got:-an unreadable version}, the pin is $MARKDOWNLINT_VERSION; a different version is a different ruleset. npm install -g markdownlint-cli2@$MARKDOWNLINT_VERSION, or re-run with LINT_ALLOW_UNPINNED=1."
    fi
  elif ! command -v npx >/dev/null 2>&1; then
    md_reason="npx is not installed (install Node.js; the pinned linter is markdownlint-cli2@$MARKDOWNLINT_VERSION)"
  elif [[ "$FETCH" == "1" ]]; then
    MD_CMD=(npx --yes "markdownlint-cli2@${MARKDOWNLINT_VERSION}")
  elif md_got="$(markdownlint_version npx --no-install "markdownlint-cli2@${MARKDOWNLINT_VERSION}")" \
       && [[ "$md_got" == "$MARKDOWNLINT_VERSION" ]]; then
    MD_CMD=(npx --no-install "markdownlint-cli2@${MARKDOWNLINT_VERSION}")
  else
    md_reason="markdownlint-cli2@$MARKDOWNLINT_VERSION is neither on PATH nor in npx's cache. npm install -g markdownlint-cli2@$MARKDOWNLINT_VERSION, or re-run with LINT_FETCH=1 to let npx fetch it."
  fi

  if [[ -n "$md_reason" ]]; then
    note_skip "markdownlint" "$md_reason"
  else
    # ci.yml runs the same binary at the same version over the same config and
    # glob; its Install markdownlint-cli2 step is what puts it on PATH there.
    md_log="$(mktemp)"
    if "${MD_CMD[@]}" --config .markdownlint-cli2.yaml '**/*.md' >"$md_log" 2>&1; then
      md_rc=0
    else
      md_rc=$?
    fi
    cat "$md_log"
    # "Linting: N files" is markdownlint-cli2's own count of what it opened,
    # which is the number that matters: a glob or an ignores: entry that
    # stopped matching leaves it at 0 and the tool still exits 0.
    linted="$(awk '/^Linting: [0-9]+ file/ { print $2; exit }' "$md_log")"
    rm -f "$md_log"
    if (( md_rc != 0 )) && [[ -z "$linted" ]]; then
      fail "markdownlint-cli2 resolved but did not run (see the output above)"
    elif [[ "${linted:-0}" == "0" ]]; then
      fail "markdownlint: linted 0 files — the glob or .markdownlint-cli2.yaml ignores: matched nothing"
    else
      ran=$((ran + 1))
      if (( md_rc == 0 )); then
        pass "markdownlint-cli2 over $linted files"
      else
        fail "markdownlint-cli2"
      fi
    fi
  fi
fi
fi  # want markdown

# --- summary ----------------------------------------------------------------
printf '\n=== lint summary ===\n'
[[ -n "${LINT_CHECKS:-}" ]] && printf 'checks selected: %s\n' "$CHECKS"
if (( ${#SKIPS[@]} > 0 )); then
  printf 'skipped:\n'
  for s in "${SKIPS[@]}"; do printf '  - %s\n' "$s"; done
fi
selected=0
for c in $CHECKS; do selected=$((selected + 1)); done
printf 'linters that ran: %d of %d selected\n' "$ran" "$selected"

# The floor the rest of the suite rests on. Every check above reports a missing
# tool as a named skip, which is right for one tool out of six — and wrong for
# all of them, because a machine with nothing installed would otherwise be
# handed a green lint. A suite that checked nothing must not pass.
if (( ran == 0 )); then
  printf 'no linter ran — every tool was missing or unpinned, so nothing was checked\n' >&2
  rc=1
fi

# A skip is honest about what was not checked, and on a developer's machine that
# is the right trade: a missing Hadolint should not stop them learning that
# markdownlint is unhappy. It is the wrong trade anywhere the tools were just
# installed on purpose, where a skip means an install silently stopped working
# and the gate quietly shrank. CI sets this.
if [[ "$STRICT" == "1" ]] && (( ${#SKIPS[@]} > 0 )); then
  printf 'LINT_STRICT=1 and %d linter(s) were skipped — the gate is smaller than it claims\n' \
    "${#SKIPS[@]}" >&2
  rc=1
fi

if (( rc == 0 )); then
  printf 'lint clean\n'
else
  printf 'lint failed\n'
fi
exit "$rc"
