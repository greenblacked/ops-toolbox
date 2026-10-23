#!/usr/bin/env bash
# Install the hooks that block the commits you regret.

set -euo pipefail

DRY_RUN=0
FORCE=0
COMMIT_MSG=0
TOKEN_SCAN=0
PRE_PUSH=0
PROTECT=()
CMD=""

usage() {
  cat <<EOF
git_hooks_install.sh - install, inspect and remove this repository's hooks

Hooks are written into .git/hooks of the current repository. Each body is
embedded in this script rather than copied from a directory, so a hook keeps
working after this script is deleted, moved, or was never checked out beside
the repository it installed into.

pre-commit (always installed) refuses to commit:

  large files      anything staged over --max-size (default 1024 KB). Git never
                   forgets a blob, so a binary committed once is in the clone
                   forever — see git_size_report.sh.
  conflict markers <<<<<<<, =======, >>>>>>> left in a staged file.
  private keys     a staged file whose contents open with a PEM private-key
                   header.

commit-msg (only with --commit-msg) refuses a subject line that is not a
Conventional Commit — 'type(optional scope): subject', with an optional '!'
marking a breaking change:

  feat(git): add a stale branch report
  fix!: stop pushing tags by default

Types are the usual set: build, chore, ci, docs, feat, fix, perf, refactor,
revert, style, test. Messages git generates itself — merges, reverts, and the
fixup!/squash! prefixes — are exempt, because rejecting those would break
rebasing rather than improve a changelog. It is off by default: a message
convention is a team decision, and a hook that imposes one on a repository
that has not agreed to it is a hook that gets bypassed on its first use.

pre-push (only with --pre-push) refuses the pushes that are expensive to undo:

  protected branches  any push to main or master (or the --protect names),
                      named as a deletion or a non-fast-forward when it is one
  unfinished commits  pushing a fixup!, squash! or amend! commit, or one whose
                      subject starts with WIP (as a word), to any branch

Bypass one push deliberately with 'git push --no-verify' or by setting
GIT_ALLOW_PROTECTED_PUSH=1 for it. Off by default for the same reason as
commit-msg: whether a branch takes direct pushes is a team decision.

The hooks are deliberately small. A hook that takes a second to run gets
bypassed with --no-verify and then never runs again, so they check only things
that are cheap and genuinely hard to undo.

Usage:
  $(basename "$0") install [--commit-msg] [--pre-push [--protect NAME]...] [--token-scan]
                          [--force] [--dry-run] [--max-size KB]
  $(basename "$0") status
  $(basename "$0") uninstall [--dry-run]

Commands:
  install    Write the hooks. Refuses to clobber an unrelated existing hook
             unless --force is given, which backs it up first.
  status     Report which hooks are installed and up to date. Read-only.
  uninstall  Remove every hook this script installed, restoring a backup if it
             made one.

Options:
  --commit-msg   Also install the Conventional Commits commit-msg hook
  --pre-push     Also install the protected-branch and unfinished-commit
                 pre-push hook
  --protect NAME Branch the pre-push hook protects (repeatable; replaces the
                 default main and master; needs --pre-push)
  --token-scan   Also reject high-confidence GitHub and GitLab tokens
  --max-size KB  Largest staged file the pre-commit hook allows (default: 1024)
  --force        Overwrite an existing unrelated hook, backing it up first
  --dry-run      Show what would happen without writing anything
  --help, -h     Show this help

Exit codes: 0 success, 1 refused to act, 2 not a git repo, 3 usage,
4 nothing to do (for uninstall: no hook installed)
EOF
}

require_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    printf "%s requires a value\n" "$option" >&2
    exit 3
  fi
}

MAX_SIZE_KB=1024

while (( $# > 0 )); do
  case "$1" in
    install|status|uninstall)
      if [[ -n "$CMD" ]]; then
        printf "only one command at a time\n" >&2
        exit 3
      fi
      CMD="$1"
      ;;
    --max-size)
      require_value "$1" "${2:-}"; shift; MAX_SIZE_KB="$1" ;;
    --max-size=*)
      MAX_SIZE_KB="${1#*=}"; require_value "--max-size" "$MAX_SIZE_KB" ;;
    --commit-msg) COMMIT_MSG=1 ;;
    --pre-push)   PRE_PUSH=1 ;;
    --protect)
      require_value "$1" "${2:-}"; shift; PROTECT+=("$1") ;;
    --protect=*)
      value="${1#*=}"; require_value "--protect" "$value"; PROTECT+=("$value") ;;
    --token-scan) TOKEN_SCAN=1 ;;
    --force)   FORCE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      printf "unknown argument: %s\n" "$1" >&2
      usage >&2
      exit 3
      ;;
  esac
  shift
done

case "$MAX_SIZE_KB" in
  ''|*[!0-9]*)
    printf -- "--max-size requires a whole number of KB, got: %s\n" "$MAX_SIZE_KB" >&2
    exit 3
    ;;
esac

# The names are written into the hook body as plain words, so anything that
# is not an ordinary branch-name character is refused here rather than
# escaped there.
for name in "${PROTECT[@]+"${PROTECT[@]}"}"; do
  if [[ ! "$name" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    printf -- "--protect takes a branch name, got: %s\n" "$name" >&2
    exit 3
  fi
done
if (( ${#PROTECT[@]} > 0 && PRE_PUSH == 0 )); then
  printf -- "--protect only applies with --pre-push\n" >&2
  exit 3
fi
if (( ${#PROTECT[@]} > 0 )); then
  PROTECTED_LIST="${PROTECT[*]}"
else
  PROTECTED_LIST="main master"
fi

if [[ -z "$CMD" ]]; then
  usage >&2
  exit 3
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf "not inside a Git repository\n" >&2
  exit 2
fi

# --git-path resolves correctly inside a worktree or a submodule, where
# .git is a file pointing elsewhere rather than a directory.
HOOK_DIR="$(git rev-parse --git-path hooks)"
HOOK="$HOOK_DIR/pre-commit"
MSG_HOOK="$HOOK_DIR/commit-msg"
# Named after the tool that writes it, not after this repository — a stranger
# finding the file needs to know what to run to undo it, and a repository name
# is the one thing about a copied script that will not travel with it.
BACKUP="$HOOK.hooks-install-backup"
MSG_BACKUP="$MSG_HOOK.hooks-install-backup"
PUSH_HOOK="$HOOK_DIR/pre-push"
PUSH_BACKUP="$PUSH_HOOK.hooks-install-backup"

# Bumped whenever a hook body below changes, so `status` can tell an
# out-of-date hook from a current one instead of just reporting "present".
# Versioned per hook: adding the commit-msg hook did not change the pre-commit
# one, and reporting every existing installation as stale would be a lie.
HOOK_VERSION=3
MSG_HOOK_VERSION=1
PUSH_HOOK_VERSION=1
MARKER="# managed by git_hooks_install.sh v"

hook_body() {
  cat <<EOF
#!/usr/bin/env bash
$MARKER$HOOK_VERSION
# Reinstall or update with: git_hooks_install.sh install --force
#
# Checks only what is cheap and hard to undo. A slow hook gets bypassed with
# --no-verify and then never runs again.
set -uo pipefail

max_kb=$MAX_SIZE_KB
token_scan=$TOKEN_SCAN
failed=0

# Staged, non-deleted paths, NUL-delimited so spaces and newlines survive.
while IFS= read -r -d '' path; do
  # Every check below reads the *staged blob*, never the working tree. The two
  # diverge constantly — \`git add -p\` stages one hunk of a dirty file, and
  # editing a file after adding it leaves the index behind — and it is the
  # staged content that is about to become a commit. Reading the working tree
  # instead both misses real problems and blocks clean commits.
  blob="\$(git rev-parse --verify --quiet ":\$path")" || continue
  [ -n "\$blob" ] || continue
  # Submodule pointers resolve to a commit, not a blob; nothing to inspect.
  [ "\$(git cat-file -t "\$blob" 2>/dev/null)" = "blob" ] || continue

  # --- size ---
  size_kb=\$(( \$(git cat-file -s "\$blob") / 1024 ))
  if (( size_kb > max_kb )); then
    printf 'pre-commit: %s is %s KB, over the %s KB limit\n' "\$path" "\$size_kb" "\$max_kb" >&2
    failed=1
  fi

  # --- conflict markers ---
  # Anchored to line start and requiring 7 characters, so ordinary prose
  # containing "<<<" or a diff quoted in a commit does not trip it.
  # grep -c rather than -q: -q stops reading on the first match, which closes
  # the pipe under the script's own pipefail and turns a hit into a miss.
  markers="\$(git cat-file blob "\$blob" 2>/dev/null | grep -cE '^(<{7}|={7}|>{7})( |\$)')" || true
  if [ "\${markers:-0}" -gt 0 ]; then
    printf 'pre-commit: %s contains a merge conflict marker\n' "\$path" >&2
    failed=1
  fi

  # --- private keys ---
  first_bytes="\$(git cat-file blob "\$blob" 2>/dev/null | head -c 100)" || true
  case "\$first_bytes" in
    *"-----BEGIN "*"PRIVATE KEY-----"*)
      printf 'pre-commit: %s looks like a private key\n' "\$path" >&2
      failed=1
      ;;
  esac

  # --- high-confidence access tokens (opt-in at install time) ---
  # Keep this deliberately narrow: a noisy secret hook is bypassed, which is
  # worse than a smaller rule set that developers trust.
  if (( token_scan == 1 )); then
    token_hits="\$(git cat-file blob "\$blob" 2>/dev/null | grep -aEc '(gh[pousr]_[A-Za-z0-9]{36,255}|github_pat_[A-Za-z0-9_]{20,255}|glpat-[A-Za-z0-9_-]{20,255})')" || true
    if [ "\${token_hits:-0}" -gt 0 ]; then
      printf 'pre-commit: %s looks like it contains an access token\n' "\$path" >&2
      failed=1
    fi
  fi
done < <(git diff --cached --name-only --diff-filter=d -z)

if (( failed )); then
  printf '\ncommit refused. Fix the above, or bypass deliberately with:\n' >&2
  printf '  git commit --no-verify\n' >&2
  exit 1
fi
exit 0
EOF
}

msg_hook_body() {
  cat <<EOF
#!/usr/bin/env bash
$MARKER$MSG_HOOK_VERSION
# Reinstall or update with: git_hooks_install.sh install --commit-msg --force
#
# Refuses a subject line that is not a Conventional Commit. Messages git writes
# itself are exempt: rejecting those would break a rebase rather than improve a
# changelog.
set -uo pipefail

msg_file="\${1:-}"
[ -n "\$msg_file" ] || exit 0
[ -f "\$msg_file" ] || exit 0

# The subject is the first line that is neither blank nor a comment. Taking
# line 1 instead would reject every message written under commit.verbose or
# from a template, where the first line is routinely a comment.
subject=""
while IFS= read -r line; do
  case "\$line" in
    '#'*) continue ;;
    '')   continue ;;
  esac
  subject="\$line"
  break
done < "\$msg_file"

# An empty message is git's own business — it aborts the commit itself, with a
# better message than this hook could give.
[ -n "\$subject" ] || exit 0

case "\$subject" in
  Merge\ *|Revert\ *|fixup!*|squash!*|amend!*) exit 0 ;;
esac

if [[ "\$subject" =~ ^(build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test)(\([a-zA-Z0-9._/-]+\))?!?:\ .+ ]]; then
  exit 0
fi

printf 'commit-msg: the subject is not a Conventional Commit:\n\n' >&2
printf '  %s\n\n' "\$subject" >&2
printf 'expected: type(optional scope): subject\n' >&2
printf 'types:    build chore ci docs feat fix perf refactor revert style test\n' >&2
printf 'examples: feat(git): add a stale branch report\n' >&2
printf '          fix!: stop pushing tags by default\n\n' >&2
printf 'The message you wrote is still in %s. Edit and retry with:\n' "\$msg_file" >&2
printf '  git commit --edit --file %s\n\n' "\$msg_file" >&2
printf 'Or bypass deliberately with:\n' >&2
printf '  git commit --no-verify\n' >&2
exit 1
EOF
}

push_hook_body() {
  cat <<EOF
#!/usr/bin/env bash
$MARKER$PUSH_HOOK_VERSION
# Reinstall or update with: git_hooks_install.sh install --pre-push --force
#
# Refuses the pushes that are expensive to undo: anything to a protected
# branch, and commits that were meant to be squashed before anyone saw them.
# git passes the remote name and URL as arguments and one line per ref on
# stdin: <local ref> <local sha> <remote ref> <remote sha>.
set -uo pipefail

# The documented per-push bypass, alongside git push --no-verify.
if [ "\${GIT_ALLOW_PROTECTED_PUSH-}" = "1" ]; then
  exit 0
fi

remote="\${1:-}"
protected="$PROTECTED_LIST"
failed=0

# An all-zero object name means "no object": a deletion when it is the local
# side, a new branch when it is the remote side. Tested by content rather than
# length so SHA-256 repositories work too.
is_zero() {
  case "\$1" in
    ''|*[!0]*) return 1 ;;
  esac
  return 0
}

is_protected() {
  local name
  for name in \$protected; do
    [ "\$name" = "\$1" ] && return 0
  done
  return 1
}

# Commits already on the remote are not this push's business, but only the
# remote can say what it has: remote-tracking refs go stale, and one that
# still points at an unfinished commit would hide it from a new branch. So a
# new branch is compared with what the remote advertises (git ls-remote),
# asked only when a new branch is pushed. When the remote cannot be listed,
# the newest \$scan_bound commits of the pushed history are read instead.
scan_bound=200
adv_ok=0
adv_shas=""

load_advertised() {
  local target listing
  target="\${2:-\$remote}"
  [ -n "\$target" ] || return 0
  listing="\$(GIT_TERMINAL_PROMPT=0 git ls-remote "\$target" 2>/dev/null)" || return 0
  adv_ok=1
  # Only objects this clone has can be excluded; the rest are not its history.
  adv_shas="\$(printf '%s\\n' "\$listing" | awk 'NF >= 2 { print \$1 "^{commit}" }' |
    git cat-file --batch-check 2>/dev/null | awk '\$2 == "commit" { print \$1 }')" || adv_shas=""
}

new_branch_subjects() {
  local sha
  load_advertised "\$@"
  if [ "\$adv_ok" -eq 0 ]; then
    git log --max-count="\$scan_bound" --format='%h %s' "\$local_sha" 2>/dev/null
    return
  fi
  {
    printf '%s\\n' "\$local_sha"
    for sha in \$adv_shas; do printf '^%s\\n' "\$sha"; done
  } | git log --format='%h %s' --stdin 2>/dev/null
}

while read -r _local_ref local_sha remote_ref remote_sha; do
  [ -n "\${remote_ref:-}" ] || continue
  branch=""
  case "\$remote_ref" in
    refs/heads/*) branch="\${remote_ref#refs/heads/}" ;;
  esac

  # Protected first, so a push to one is a single clear refusal.
  if [ -n "\$branch" ] && is_protected "\$branch"; then
    if is_zero "\$local_sha"; then
      printf 'pre-push: deleting the protected branch %s is blocked\n' "\$branch" >&2
    elif ! is_zero "\$remote_sha" &&
      { ! git cat-file -e "\$remote_sha^{commit}" 2>/dev/null ||
        ! git merge-base --is-ancestor "\$remote_sha" "\$local_sha" 2>/dev/null; }; then
      # An old tip this clone does not have cannot be proven to be an
      # ancestor, so it is treated as the rewrite it may be.
      printf 'pre-push: %s would be rewritten by a non-fast-forward (force) push; blocked\n' "\$branch" >&2
    else
      printf 'pre-push: direct pushes to the protected branch %s are blocked\n' "\$branch" >&2
    fi
    failed=1
    continue
  fi

  # Deleting an unprotected branch pushes no commits.
  is_zero "\$local_sha" && continue

  if ! is_zero "\$remote_sha" && git cat-file -e "\$remote_sha^{commit}" 2>/dev/null; then
    subjects="\$(git log --format='%h %s' "\$remote_sha..\$local_sha" 2>/dev/null)" || subjects=""
  else
    subjects="\$(new_branch_subjects "\$@")" || subjects=""
  fi
  while IFS= read -r line; do
    [ -n "\$line" ] || continue
    subject="\${line#* }"
    case "\$subject" in
      fixup!*|squash!*|amend!*|WIP|wip|WIP[![:alpha:]]*|wip[![:alpha:]]*)
        printf 'pre-push: unfinished commit on %s: %s\n' "\${branch:-\$remote_ref}" "\$line" >&2
        failed=1
        ;;
    esac
  done <<< "\$subjects"
done

if [ "\$failed" -ne 0 ]; then
  printf '\npush refused. Fix the above, or bypass deliberately with:\n' >&2
  printf '  git push --no-verify\n' >&2
  printf '  GIT_ALLOW_PROTECTED_PUSH=1 git push ...\n' >&2
  exit 1
fi
exit 0
EOF
}

installed_version() {
  local hook="$1"
  [[ -f "$hook" ]] || return 1
  sed -n "s|^${MARKER}\([0-9][0-9]*\).*|\1|p" "$hook" | head -n 1
}

report_status() {
  local hook="$1" label="$2" want="$3" backup="$4" flags="$5" version
  version="$(installed_version "$hook" || true)"
  if [[ -z "$version" ]]; then
    printf "a %s hook exists at %s, but it was not installed by this script\n" \
      "$label" "$hook"
    printf "install --force would back it up to %s\n" "$(basename "$backup")"
    return 0
  fi
  if [[ "$version" == "$want" ]]; then
    printf "%s hook installed and current (v%s)\n" "$label" "$version"
  else
    printf "%s hook installed but out of date (v%s, current is v%s)\n" \
      "$label" "$version" "$want"
    printf "update with: %s %s\n" "$(basename "$0")" "$flags"
  fi
}

# Checked for every hook before any of them is written, so a foreign hook of
# one kind cannot leave the other half-installed.
refuse_foreign() {
  local hook="$1" label="$2"
  if [[ -f "$hook" ]] && [[ -z "$(installed_version "$hook" || true)" ]] && (( FORCE == 0 )); then
    printf "a %s hook already exists at %s and was not installed by this script\n" \
      "$label" "$hook" >&2
    printf "pass --force to back it up and replace it\n" >&2
    exit 1
  fi
}

preview_install() {
  local hook="$1" backup="$2" note="$3"
  if [[ -f "$hook" ]] && [[ -z "$(installed_version "$hook" || true)" ]]; then
    printf "dry-run: would run: mv %s %s\n" "$hook" "$backup"
  fi
  printf "dry-run: would write %s (%s)\n" "$hook" "$note"
  printf "dry-run: would run: chmod +x %s\n" "$hook"
}

write_hook() {
  local hook="$1" backup="$2" body="$3"
  if [[ -f "$hook" ]] && [[ -z "$(installed_version "$hook" || true)" ]]; then
    mv "$hook" "$backup"
    printf "backed up the existing hook to %s\n" "$backup"
  fi
  "$body" > "$hook"
  chmod +x "$hook"
}

case "$CMD" in
  status)
    if [[ ! -f "$HOOK" ]]; then
      printf "no pre-commit hook installed at %s\n" "$HOOK"
    else
      report_status "$HOOK" "pre-commit" "$HOOK_VERSION" "$BACKUP" "install --force"
    fi
    if [[ ! -f "$MSG_HOOK" ]]; then
      printf "no commit-msg hook installed; add one with: %s install --commit-msg\n" \
        "$(basename "$0")"
    else
      report_status "$MSG_HOOK" "commit-msg" "$MSG_HOOK_VERSION" "$MSG_BACKUP" \
        "install --commit-msg --force"
    fi
    if [[ ! -f "$PUSH_HOOK" ]]; then
      printf "no pre-push hook installed; add one with: %s install --pre-push\n" \
        "$(basename "$0")"
    else
      report_status "$PUSH_HOOK" "pre-push" "$PUSH_HOOK_VERSION" "$PUSH_BACKUP" \
        "install --pre-push --force"
    fi
    ;;

  install)
    refuse_foreign "$HOOK" "pre-commit"
    if (( COMMIT_MSG == 1 )); then
      refuse_foreign "$MSG_HOOK" "commit-msg"
    fi
    if (( PRE_PUSH == 1 )); then
      refuse_foreign "$PUSH_HOOK" "pre-push"
    fi

    if (( DRY_RUN == 1 )); then
      token_note="disabled"
      (( TOKEN_SCAN == 1 )) && token_note="enabled"
      preview_install "$HOOK" "$BACKUP" "max-size $MAX_SIZE_KB KB, token-scan $token_note"
      if (( COMMIT_MSG == 1 )); then
        preview_install "$MSG_HOOK" "$MSG_BACKUP" "conventional commit subjects"
      fi
      if (( PRE_PUSH == 1 )); then
        preview_install "$PUSH_HOOK" "$PUSH_BACKUP" \
          "protected: $PROTECTED_LIST, wip and fixup guard"
      fi
      printf "dry-run complete; no changes written\n"
      exit 0
    fi

    mkdir -p "$HOOK_DIR"
    write_hook "$HOOK" "$BACKUP" hook_body
    token_note="disabled"
    (( TOKEN_SCAN == 1 )) && token_note="enabled"
    printf "installed pre-commit hook (v%s, max-size %s KB, token-scan %s)\n" \
      "$HOOK_VERSION" "$MAX_SIZE_KB" "$token_note"
    if (( COMMIT_MSG == 1 )); then
      write_hook "$MSG_HOOK" "$MSG_BACKUP" msg_hook_body
      printf "installed commit-msg hook (v%s, conventional commit subjects)\n" \
        "$MSG_HOOK_VERSION"
    fi
    if (( PRE_PUSH == 1 )); then
      write_hook "$PUSH_HOOK" "$PUSH_BACKUP" push_hook_body
      printf "installed pre-push hook (v%s, protected: %s, wip and fixup guard)\n" \
        "$PUSH_HOOK_VERSION" "$PROTECTED_LIST"
    fi
    printf "verify with: %s status\n" "$(basename "$0")"
    ;;

  uninstall)
    present=0
    removed=0
    for name in pre-commit commit-msg pre-push; do
      case "$name" in
        pre-commit) hook="$HOOK";      backup="$BACKUP" ;;
        commit-msg) hook="$MSG_HOOK";  backup="$MSG_BACKUP" ;;
        pre-push)   hook="$PUSH_HOOK"; backup="$PUSH_BACKUP" ;;
      esac
      [[ -f "$hook" ]] || continue
      present=$((present + 1))

      if [[ -z "$(installed_version "$hook" || true)" ]]; then
        printf "the hook at %s was not installed by this script; refusing to remove it\n" \
          "$hook" >&2
        continue
      fi

      removed=$((removed + 1))
      if (( DRY_RUN == 1 )); then
        printf "dry-run: would run: rm %s\n" "$hook"
        if [[ -f "$backup" ]]; then
          printf "dry-run: would run: mv %s %s\n" "$backup" "$hook"
        fi
        continue
      fi

      rm -f "$hook"
      if [[ -f "$backup" ]]; then
        mv "$backup" "$hook"
        printf "removed the %s hook and restored the backup that was there before\n" "$name"
      else
        printf "removed the %s hook\n" "$name"
      fi
    done

    if (( present == 0 )); then
      printf "no hook to remove\n"
      exit 4
    fi
    # Everything present belongs to somebody else, and each one has said so on
    # stderr already.
    if (( removed == 0 )); then
      exit 1
    fi
    if (( DRY_RUN == 1 )); then
      printf "dry-run complete; no changes written\n"
    fi
    ;;
esac
