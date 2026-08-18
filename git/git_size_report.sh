#!/usr/bin/env bash
# Report what is making this repository big, and where it came from.

set -euo pipefail

TOP=20
FAST=0
THRESHOLD=0
REFS=()

usage() {
  cat <<EOF
git_size_report.sh - show what is taking up space in this repository

Read-only. Reports the on-disk totals, then the largest blobs in history with
the paths they were stored under, so a 200 MB clone can be traced back to the
file that caused it.

Note that history is what counts: deleting a large file in a later commit does
not shrink the repository, because the blob is still reachable from the commit
that added it. That is why this walks every object rather than the worktree.

Usage:
  $(basename "$0") [--top N] [--threshold BYTES] [--ref REF] [--fast]

Options:
  --top N            How many objects to list (default: 20)
  --threshold BYTES  Only list objects at least this large (default: 0)
  --ref REF          Limit history to objects reachable from REF (repeatable)
  --fast             On-disk totals only; skip the history walk
  --help, -h         Show this help

The history walk is O(all objects) and takes a while on a large repository.
--fast answers "how big is it" in a second; the full run answers "why".

Exit codes: 0 success, 2 not a git repo, 3 usage, 4 ref not found
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

require_number() {
  local option="$1"
  local value="$2"
  case "$value" in
    ''|*[!0-9]*)
      printf "%s requires a whole number, got: %s\n" "$option" "$value" >&2
      exit 3
      ;;
  esac
}

while (( $# > 0 )); do
  case "$1" in
    --top)
      require_value "$1" "${2:-}"; shift; require_number "--top" "$1"; TOP="$1" ;;
    --top=*)
      TOP="${1#*=}"; require_number "--top" "$TOP" ;;
    --threshold)
      require_value "$1" "${2:-}"; shift; require_number "--threshold" "$1"; THRESHOLD="$1" ;;
    --threshold=*)
      THRESHOLD="${1#*=}"; require_number "--threshold" "$THRESHOLD" ;;
    --fast)
      FAST=1 ;;
    --ref)
      require_value "$1" "${2:-}"; shift; REFS+=("$1") ;;
    --ref=*)
      value="${1#*=}"; require_value "--ref" "$value"; REFS+=("$value") ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      printf "unknown argument: %s\n" "$1" >&2
      usage >&2
      exit 3
      ;;
  esac
  shift
done

if (( FAST == 1 && ${#REFS[@]} > 0 )); then
  printf -- "--ref cannot be combined with --fast because --fast skips history\n" >&2
  exit 3
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf "not inside a Git repository\n" >&2
  exit 2
fi

printf "=== on disk ===\n"
git count-objects -vH | sed 's/^/  /'

if (( FAST == 1 )); then
  printf "\n--fast given; skipping the history walk\n"
  exit 0
fi

printf "\n=== largest objects in history ===\n"

rev_args=(--objects)
if (( ${#REFS[@]} == 0 )); then
  rev_args+=(--all)
else
  for ref in "${REFS[@]}"; do
    if ! git rev-parse --verify --quiet "${ref}^{object}" >/dev/null; then
      printf "ref not found: %s\n" "$ref" >&2
      exit 4
    fi
    rev_args+=("$ref")
  done
fi

# Aggregation happens in awk, not bash: Bash 3.2 has no associative arrays (see
# CONTRIBUTING.md), and a shell loop over every object in a large repository is
# slow enough to make the script one nobody runs twice.
#
# rev-list --objects prints "<sha> [path]"; cat-file --batch-check turns each
# into "<sha> <type> <size>". Joining them gives size-per-path, which is the
# thing you actually want — a sha alone tells you nothing about what to delete.
git rev-list "${rev_args[@]}" |
  git cat-file --batch-check='%(objectname) %(objecttype) %(objectsize) %(rest)' |
  awk -v top="$TOP" -v threshold="$THRESHOLD" '
    $2 != "blob" { next }
    $3 < threshold { next }
    {
      size = $3
      path = ""
      for (i = 4; i <= NF; i++) { path = path (i > 4 ? " " : "") $i }
      if (path == "") { path = "(no path — unreferenced or a tree/tag payload)" }

      total += size
      count++

      # Largest single blob per path, and the total that path accounts for
      # across every version of it ever committed.
      if (size > peak[path]) { peak[path] = size }
      sum[path] += size
      versions[path]++
    }
    END {
      if (count == 0) { print "  no blobs matched"; exit 0 }

      printf "  %d blobs, %s total across all history\n\n", count, human(total)
      printf "  %-10s %-10s %-6s %s\n", "LARGEST", "ALL VERS", "COUNT", "PATH"

      n = 0
      for (p in sum) { order[n++] = p }
      # Insertion sort by cumulative size. n is the number of distinct paths,
      # not objects, so this stays small even on a big repository.
      for (i = 1; i < n; i++) {
        key = order[i]
        for (j = i - 1; j >= 0 && sum[order[j]] < sum[key]; j--) { order[j+1] = order[j] }
        order[j+1] = key
      }
      shown = (n < top) ? n : top
      for (i = 0; i < shown; i++) {
        p = order[i]
        printf "  %-10s %-10s %-6d %s\n", human(peak[p]), human(sum[p]), versions[p], p
      }
      if (n > shown) { printf "\n  ... %d more paths (--top %d to widen)\n", n - shown, n }
    }

    function human(b) {
      if (b >= 1073741824) { return sprintf("%.2f GB", b / 1073741824) }
      if (b >= 1048576)    { return sprintf("%.1f MB", b / 1048576) }
      if (b >= 1024)       { return sprintf("%.0f KB", b / 1024) }
      return sprintf("%d B", b)
    }
  '

cat <<'EOF'

=== what to do about it ===
  Repacking may reclaim loose objects:
    git gc --aggressive --prune=now

  If a path above should never have been committed, rewriting history is the
  only way to remove it. This changes every commit sha, so coordinate first:
    git filter-repo --path <path> --invert-paths

  A large blob that is still wanted belongs in Git LFS rather than history.
EOF
