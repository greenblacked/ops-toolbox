# shellcheck shell=bash
# Shared discovery: which tracked files are command-line scripts?
#
# Sourced, never executed — so it has no shebang and is not executable, which
# is also what keeps it out of its own results.
#
# The rule has three legs and deliberately has no per-file opt-out list. A list
# of exemptions is the thing that rots: the macOS suite's hardcoded --help list
# silently stopped covering brewfile.sh and launchd/stay_fresh_agent.sh, which
# is the drift this discovery exists to prevent. Exemptions here are by *role*,
# expressed as path patterns, so a new script in an existing package is covered
# by the commit that creates it.
#
#   1. tracked, with a .sh or .py extension
#   2. executable in the index, and the first line is a shebang
#      — this is not a heuristic, it is what "is a CLI" means here. Every file
#        that legitimately has no --help fails a leg: git_aliases.zsh and
#        zsh_aliases.zsh are sourced (no shebang, mode 644), the RouterOS .lua
#        scripts and the Git Bash dotfiles are not in the glob.
#   3. not a test harness or a suite runner
#
# Usage:
#   . "$REPO_ROOT/test-env/lib/discover_clis.sh"
#   while IFS= read -r -d '' f; do ...; done < <(discover_clis "$REPO_ROOT")

discover_clis() {
  local repo_root="${1:-.}"
  local record mode path
  (
    cd "$repo_root" || return 1
    while IFS= read -r -d '' record; do
      # Record is "<mode> <sha> <stage>\t<path>".
      mode="${record%% *}"
      path="${record#*$'\t'}"

      [ "$mode" = "100755" ] || continue

      case "$path" in
        */tests/*)          continue ;;  # test bodies and their fixtures
        test-env/*/run.sh)  continue ;;  # suite runners
        test-env/lib/*)     continue ;;  # sourced helpers like this one
      esac

      head -n 1 -- "$path" | grep -q '^#!' || continue

      printf '%s\0' "$path"
    done < <(git ls-files -s -z -- '*.sh' '*.py')
  )
}
