# Print every environment variable a script reads from its environment and
# never assigns itself — one name per line, unsorted.
#
# Usage: awk -f host_env_vars.awk -v lang=sh FILE
#        awk -f host_env_vars.awk -v lang=py FILE
#
# One pass, one process, on purpose. The reads and the assignments have to be
# compared, and every way of doing that across two streams invites the failure
# this repository has already paid for twice: under `set -o pipefail`, a reader
# that stops early — `grep -q` on a match, `awk '{exit}'` at a heading — kills
# the writer with SIGPIPE and the pipeline reports 141, so a match reads as a
# miss. That is what made `changelog.sh preview` exit 141, and a draft of the
# check that calls this file skipped a third of its subjects the same way.
# Deciding inside one awk process removes the shape rather than working around
# it.
#
# The regexes are literals rather than function arguments. Passed as a string,
# `/\$\{/` loses its backslashes, matches empty, and the scan loop never
# advances: the first draft of this file hung instead of failing.
#
# Each loop also copies RSTART and RLENGTH before doing anything else with the
# match. They are globals, and remember() runs a match() of its own, so reading
# them afterwards advances the scan by the inner match's offsets: a line with
# two variables was rescanned seven times, and remember()'s own no-match return
# would leave RLENGTH at -1, where substr(s, 0) returns the string whole and the
# loop stops advancing at all.

function remember(kind, tok,    name) {
  if (!match(tok, /[A-Z][A-Z0-9_]*/)) return
  name = substr(tok, RSTART, RLENGTH)
  if (length(name) < 3) return
  if (kind == "assign") assigned[name] = 1; else reads[name] = 1
}

# A name inside a comment describes behaviour instead of having it. Skipping
# comments is what stops a suite's own explanation of why it unsets a variable
# from counting as the unset.
/^[ \t]*#/ { next }

lang == "sh" {
  # Read as ${NAME:-default}, ${NAME:+alt} or ${NAME}.
  s = $0
  while (match(s, /\$\{[A-Z][A-Z0-9_]*(:-|:\+|\})/)) {
    start = RSTART; len = RLENGTH
    if (len <= 0) break
    remember("read", substr(s, start, len))
    s = substr(s, start + len)
  }
  # Assigned as NAME= at the start of a line, after a separator, or as a
  # one-command prefix such as `CAPTURE_STDERR=1 capture_cmd ...`. local,
  # export, readonly and `declare -x` spellings all count.
  s = $0
  while (match(s, /(^|[;&|(]|[ \t])(local |export |readonly |declare -[a-zA-Z]+ )?[A-Z][A-Z0-9_]*=/)) {
    start = RSTART; len = RLENGTH
    if (len <= 0) break
    remember("assign", substr(s, start, len))
    s = substr(s, start + len)
  }
}

lang == "py" {
  # Read as os.environ["NAME"], os.environ.get("NAME") or os.getenv("NAME").
  s = $0
  while (match(s, /(os\.environ(\.get)?\(?\[?|os\.getenv\()["'][A-Z][A-Z0-9_]*/)) {
    start = RSTART; len = RLENGTH
    if (len <= 0) break
    tok = substr(s, start, len)
    sub(/^os\.[a-z]*/, "", tok)   # os.getenv would otherwise contribute no name
    remember("read", tok)
    s = substr(s, start + len)
  }
  # os.environ["NAME"] = ... is the only way a script sets its own.
  s = $0
  while (match(s, /os\.environ\[["'][A-Z][A-Z0-9_]*["']\][ \t]*=[^=]/)) {
    start = RSTART; len = RLENGTH
    if (len <= 0) break
    tok = substr(s, start, len)
    sub(/^os\.[a-z]*/, "", tok)
    remember("assign", tok)
    s = substr(s, start + len)
  }
}

END {
  for (name in reads) if (!(name in assigned)) print name
}
