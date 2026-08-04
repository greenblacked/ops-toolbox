#!/usr/bin/env bash
# Install a pre-commit hook that blocks the commits you regret.

set -euo pipefail

DRY_RUN=0
FORCE=0
CMD=""

usage() {
  cat <<EOF
git_hooks_install.sh - install, inspect and remove this repository's pre-commit hook

The hook is written into .git/hooks/pre-commit of the current repository. Its
body is embedded in this script rather than copied from a directory, so the
hook keeps working after this script is deleted, moved, or was never checked
out beside the repository it installed into.

What the hook refuses to commit:

  large files      anything staged over --max-size (default 1024 KB). Git never
                   forgets a blob, so a binary committed once is in the clone
                   forever — see git_size_report.sh.
  conflict markers <<<<<<<, =======, >>>>>>> left in a staged file.
  private keys     a staged file whose contents open with a PEM private-key
                   header.

It is deliberately small. A hook that takes a second to run gets bypassed with
--no-verify and then never runs again, so this checks only things that are
cheap and genuinely hard to undo.

Usage:
  $(basename "$0") install [--force] [--dry-run] [--max-size KB]
  $(basename "$0") status
  $(basename "$0") uninstall [--dry-run]

Commands:
  install    Write the hook. Refuses to clobber an unrelated existing hook
             unless --force is given, which backs it up first.
  status     Report whether the hook is installed and up to date. Read-only.
  uninstall  Remove the hook, restoring a backup if this script made one.

Options:
  --max-size KB  Largest staged file the hook allows (default: 1024)
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
# Named after the tool that writes it, not after this repository — a stranger
# finding the file needs to know what to run to undo it, and a repository name
# is the one thing about a copied script that will not travel with it.
BACKUP="$HOOK.hooks-install-backup"

# Bumped whenever the hook body below changes, so `status` can tell an
# out-of-date hook from a current one instead of just reporting "present".
HOOK_VERSION=2
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
done < <(git diff --cached --name-only --diff-filter=d -z)

if (( failed )); then
  printf '\ncommit refused. Fix the above, or bypass deliberately with:\n' >&2
  printf '  git commit --no-verify\n' >&2
  exit 1
fi
exit 0
EOF
}

installed_version() {
  [[ -f "$HOOK" ]] || return 1
  sed -n "s|^${MARKER}\([0-9][0-9]*\).*|\1|p" "$HOOK" | head -n 1
}

case "$CMD" in
  status)
    if [[ ! -f "$HOOK" ]]; then
      printf "no pre-commit hook installed at %s\n" "$HOOK"
      exit 0
    fi
    version="$(installed_version || true)"
    if [[ -z "$version" ]]; then
      printf "a pre-commit hook exists at %s, but it was not installed by this script\n" "$HOOK"
      printf "install --force would back it up to %s\n" "$(basename "$BACKUP")"
      exit 0
    fi
    if [[ "$version" == "$HOOK_VERSION" ]]; then
      printf "pre-commit hook installed and current (v%s)\n" "$version"
    else
      printf "pre-commit hook installed but out of date (v%s, current is v%s)\n" \
        "$version" "$HOOK_VERSION"
      printf "update with: %s install --force\n" "$(basename "$0")"
    fi
    ;;

  install)
    if [[ -f "$HOOK" ]] && [[ -z "$(installed_version || true)" ]] && (( FORCE == 0 )); then
      printf "a pre-commit hook already exists at %s and was not installed by this script\n" "$HOOK" >&2
      printf "pass --force to back it up and replace it\n" >&2
      exit 1
    fi

    if (( DRY_RUN == 1 )); then
      if [[ -f "$HOOK" ]] && [[ -z "$(installed_version || true)" ]]; then
        printf "dry-run: would run: mv %s %s\n" "$HOOK" "$BACKUP"
      fi
      printf "dry-run: would write %s (max-size %s KB)\n" "$HOOK" "$MAX_SIZE_KB"
      printf "dry-run: would run: chmod +x %s\n" "$HOOK"
      printf "dry-run complete; no changes written\n"
      exit 0
    fi

    mkdir -p "$HOOK_DIR"
    if [[ -f "$HOOK" ]] && [[ -z "$(installed_version || true)" ]]; then
      mv "$HOOK" "$BACKUP"
      printf "backed up the existing hook to %s\n" "$BACKUP"
    fi

    hook_body > "$HOOK"
    chmod +x "$HOOK"
    printf "installed pre-commit hook (v%s, max-size %s KB)\n" "$HOOK_VERSION" "$MAX_SIZE_KB"
    printf "verify with: %s status\n" "$(basename "$0")"
    ;;

  uninstall)
    if [[ ! -f "$HOOK" ]]; then
      printf "no pre-commit hook to remove\n"
      exit 4
    fi
    if [[ -z "$(installed_version || true)" ]]; then
      printf "the hook at %s was not installed by this script; refusing to remove it\n" "$HOOK" >&2
      exit 1
    fi

    if (( DRY_RUN == 1 )); then
      printf "dry-run: would run: rm %s\n" "$HOOK"
      [[ -f "$BACKUP" ]] && printf "dry-run: would run: mv %s %s\n" "$BACKUP" "$HOOK"
      printf "dry-run complete; no changes written\n"
      exit 0
    fi

    rm -f "$HOOK"
    if [[ -f "$BACKUP" ]]; then
      mv "$BACKUP" "$HOOK"
      printf "removed the hook and restored the backup that was there before\n"
    else
      printf "removed the pre-commit hook\n"
    fi
    ;;
esac
