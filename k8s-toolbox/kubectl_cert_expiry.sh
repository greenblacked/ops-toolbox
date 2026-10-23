#!/usr/bin/env bash
# kubectl_cert_expiry.sh
# Read-only report of expired and expiring TLS certificates in
# kubernetes.io/tls Secrets, and optionally in cert-manager Certificates.
# Reads only tls.crt; the private key is never read, printed or stored.
#
# Usage:
#   ./kubectl_cert_expiry.sh [--namespace NS] [--context CTX] [--all-namespaces]
#                            [--warn-days N] [--cert-manager]
#
# Exit codes:
#   0 expired, expiring or unreadable certificates reported
#   1 query or JSON parsing failed
#   2 kubectl, python3 or openssl missing / cannot reach cluster
#   3 bad arguments
#   4 nothing expires within the warning window
set -euo pipefail

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'; C_BLUE=$'\033[1;34m'; C_BOLD=$'\033[1m'
else
  C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''
fi

info() { printf "%s[info]%s %s\n" "$C_BLUE"   "$C_RESET" "$*"; }
ok()   { printf "%s[ ok ]%s %s\n" "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf "%s[warn]%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf "%s[err ]%s %s\n" "$C_RED"    "$C_RESET" "$*" >&2; }

require_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    printf "%s requires a value\n" "$option" >&2
    exit 3
  fi
}

usage() {
  cat <<EOF
$(basename "$0") - read-only report of expiring TLS certificates in a cluster

Usage:
  $(basename "$0") [--namespace NS] [--context CTX] [--all-namespaces]
                  [--warn-days N] [--cert-manager]

Decodes tls.crt from every kubernetes.io/tls Secret and asks openssl for its
end date. Only the public certificate is read; tls.key is never touched.
Expired and expiring certificates are listed soonest first, and a Secret whose
tls.crt is missing or unreadable is a finding too. Needs list permission on
Secrets: a Forbidden makes the run incomplete (exit 1), never a pass.

Options:
  --namespace NS, -n NS   Limit the check to one namespace
  --all-namespaces, -A    Scan every namespace (default when -n is omitted)
  --context CTX           kubectl context
  --warn-days N           Report certificates ending within N days (default: 30)
  --cert-manager          Also read cert-manager Certificates: notAfter,
                          renewalTime and a Ready condition that is False
  -h, --help              Show this help

Exit codes: 0 reported findings, 1 query or JSON parsing error,
            2 wrong environment (no kubectl, python3 or openssl), 3 usage,
            4 nothing expires within the warning window
EOF
}

NAMESPACE=""
CONTEXT=""
ALL_NS=1
KUBECTL=(kubectl)
FINDINGS=0
WARN_DAYS=30
CERT_MANAGER=0

while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -n|--namespace) require_value "$1" "${2:-}"; NAMESPACE="$2"; ALL_NS=0; shift ;;
    --namespace=*) NAMESPACE="${1#*=}"; require_value "--namespace" "$NAMESPACE"; ALL_NS=0 ;;
    -A|--all-namespaces) ALL_NS=1; NAMESPACE="" ;;
    --context) require_value "$1" "${2:-}"; CONTEXT="$2"; shift ;;
    --context=*) CONTEXT="${1#*=}"; require_value "--context" "$CONTEXT" ;;
    --warn-days) require_value "$1" "${2:-}"; WARN_DAYS="$2"; shift ;;
    --warn-days=*) WARN_DAYS="${1#*=}"; require_value "--warn-days" "$WARN_DAYS" ;;
    --cert-manager) CERT_MANAGER=1 ;;
    *)
      err "unknown option: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

if ! [[ "$WARN_DAYS" =~ ^[1-9][0-9]*$ ]]; then
  err "--warn-days must be a whole number of days, 1 or more (for example 30)"
  exit 3
fi

if ! command -v kubectl >/dev/null 2>&1; then
  err "kubectl is not installed or not on PATH"
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  err "python3 is not installed or not on PATH"
  exit 2
fi

if ! command -v openssl >/dev/null 2>&1; then
  err "openssl is not installed or not on PATH"
  exit 2
fi

if [[ -n "$CONTEXT" ]]; then
  KUBECTL+=(--context "$CONTEXT")
fi

ns_args=()
if (( ALL_NS == 1 )); then
  ns_args+=(--all-namespaces)
elif [[ -n "$NAMESPACE" ]]; then
  ns_args+=(--namespace "$NAMESPACE")
fi

if ! "${KUBECTL[@]}" cluster-info >/dev/null 2>&1; then
  err "cannot reach the cluster (check kubeconfig / context)"
  exit 2
fi

section() { printf "\n%s== %s ==%s\n" "$C_BOLD" "$*" "$C_RESET"; }

# The follow-up names the context this run read, so pasting it cannot land on
# whichever context happens to be current by then.
next_step() {
  local cmd="$1"
  if [[ -n "$CONTEXT" ]]; then
    cmd="kubectl --context $(printf '%q' "$CONTEXT") ${cmd#kubectl }"
  fi
  info "next      $cmd"
}

CHECK_ERRORS=0

# scan MODE WHAT NOUN RESOURCE [ARGS...]: one kubectl get piped straight into
# the filter. The listing never lands in a shell variable or on disk: for
# Secrets it carries every tls.key, and only the filter, which reads tls.crt
# alone, ever sees it. The exit status of both ends travels back on a last
# "P" line, because the pipe hides kubectl's own.
scan() {
  local mode="$1" what="$2" noun="$3" out last rows tag kube_rc py_rc a b
  shift 3
  out="$("${KUBECTL[@]}" get "$@" -o json 2>/dev/null | python3 -c '
import base64,binascii,datetime,json,subprocess,sys
mode=sys.argv[1]
warn_days=int(sys.argv[2])
raw=sys.stdin.read()
if not raw.strip():
  sys.exit(3)
doc=json.loads(raw)
items=doc["items"]
if not isinstance(items,list) or any(not isinstance(i,dict) for i in items):
  raise ValueError("expected a Kubernetes items list")
now=datetime.datetime.now(datetime.timezone.utc)
# A fixed table, because strptime %b follows the locale and openssl does not.
MONTHS={"Jan":1,"Feb":2,"Mar":3,"Apr":4,"May":5,"Jun":6,
        "Jul":7,"Aug":8,"Sep":9,"Oct":10,"Nov":11,"Dec":12}
def openssl_end(pem):
  try:
    run=subprocess.run(["openssl","x509","-noout","-enddate"],input=pem,
                       stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=20)
  except (OSError,subprocess.SubprocessError):
    return None
  if run.returncode != 0:
    return None
  text=run.stdout.decode("ascii","replace").strip()
  if not text.startswith("notAfter="):
    return None
  parts=text[len("notAfter="):].split()
  if len(parts) != 5 or parts[0] not in MONTHS or parts[4] != "GMT":
    return None
  try:
    hour,minute,second=(int(x) for x in parts[2].split(":"))
    return datetime.datetime(int(parts[3]),MONTHS[parts[0]],int(parts[1]),
                             hour,minute,second,tzinfo=datetime.timezone.utc)
  except ValueError:
    return None
def rfc3339(text):
  when=datetime.datetime.fromisoformat(str(text).replace("Z","+00:00"))
  if when.tzinfo is None:
    raise ValueError("timestamp without a zone")
  return when
def judge(label,end,extra=""):
  # Whole days, rounded toward zero, so "12d" means at least twelve full days.
  days=(end-now).total_seconds()/86400
  if days < 0:
    text="%s: EXPIRED %dd ago (%s)%s" % (label,int(-days),end.date().isoformat(),extra)
  elif days < warn_days:
    text="%s: EXPIRING in %dd (%s)%s" % (label,int(days),end.date().isoformat(),extra)
  else:
    return None
  return (days,text)
dated=[]
unreadable=[]
for item in items:
  meta=item.get("metadata") or {}
  ns=meta.get("namespace","")
  name=meta.get("name","")
  if not ns or not name:
    raise ValueError("metadata must identify namespace and name")
  if mode == "secrets":
    data=item.get("data") or {}
    if not isinstance(data,dict):
      raise ValueError("secret data must be an object")
    # Only the public certificate is ever read. tls.key is never touched.
    label="secret %s/%s" % (ns,name)
    look="kubectl get secret %s -n %s -o jsonpath=\x27{.data.tls\\.crt}\x27 | base64 -d | openssl x509 -noout -text" % (name,ns)
    crt=data.get("tls.crt")
    if not crt:
      unreadable.append((label+": UNREADABLE (no tls.crt)","kubectl describe secret %s -n %s" % (name,ns)))
      continue
    try:
      pem=base64.b64decode(crt,validate=True)
    except (binascii.Error,ValueError,TypeError):
      unreadable.append((label+": UNREADABLE (tls.crt is not base64)","kubectl describe secret %s -n %s" % (name,ns)))
      continue
    end=openssl_end(pem)
    if end is None:
      unreadable.append((label+": UNREADABLE (openssl could not read tls.crt)",look))
      continue
    verdict=judge(label,end)
    if verdict:
      dated.append((verdict[0],verdict[1],look))
  else:
    status=item.get("status") or {}
    label="certificate %s/%s" % (ns,name)
    look="kubectl describe certificate %s -n %s" % (name,ns)
    for c in status.get("conditions") or []:
      if not isinstance(c,dict):
        raise ValueError("conditions must be objects")
      if c.get("type") == "Ready" and c.get("status") == "False":
        message=" ".join(str(c.get("message") or c.get("reason") or "").split())[:100]
        unreadable.append((label+": not Ready: "+message,look))
    if status.get("notAfter"):
      end=rfc3339(status["notAfter"])
      extra=""
      if status.get("renewalTime"):
        extra=", renewal due %s" % rfc3339(status["renewalTime"]).date().isoformat()
      verdict=judge(label,end,extra)
      if verdict:
        dated.append((verdict[0],verdict[1],look))
rows=[]
for _,text,look in sorted(dated,key=lambda row: row[0]):
  rows.append("F\t"+text)
  rows.append("N\t"+look)
for text,look in unreadable:
  rows.append("F\t"+text)
  rows.append("N\t"+look)
rows.append("S\t%d\t%d" % (len(items),len(dated)))
print("\n".join(rows))
' "$mode" "$WARN_DAYS" 2>/dev/null
    printf '\nP\t%s\t%s' "${PIPESTATUS[0]}" "${PIPESTATUS[1]}")" || true
  last="${out##*$'\n'}"
  rows="${out%"$last"}"
  IFS=$'\t' read -r tag kube_rc py_rc <<<"$last"
  if [[ "$tag" != "P" ]] || [[ "$kube_rc" != "0" ]] || [[ "$py_rc" == "3" ]]; then
    warn "could not list $what"
    CHECK_ERRORS=$((CHECK_ERRORS + 1))
    return 0
  fi
  if [[ "$py_rc" != "0" ]]; then
    warn "could not parse $what JSON"
    CHECK_ERRORS=$((CHECK_ERRORS + 1))
    return 0
  fi
  while IFS=$'\t' read -r tag a b; do
    case "$tag" in
      F) warn "$a"; FINDINGS=$((FINDINGS + 1)) ;;
      N) next_step "$a" ;;
      S) info "checked ${a} ${noun}, ${b} within ${WARN_DAYS} days" ;;
    esac
  done <<<"$rows"
}

section "TLS Secrets"
scan secrets "TLS secrets (needs list permission on secrets)" "certificate(s)" \
  secrets "${ns_args[@]}" --field-selector type=kubernetes.io/tls

if (( CERT_MANAGER == 1 )); then
  section "cert-manager Certificates"
  scan certificates "cert-manager Certificates (is cert-manager installed?)" \
    "Certificate resource(s)" certificates.cert-manager.io "${ns_args[@]}"
fi

printf "\n"
if (( CHECK_ERRORS > 0 )); then
  err "${CHECK_ERRORS} query or JSON parsing check(s) failed; certificate check incomplete"
  exit 1
fi
if (( FINDINGS == 0 )); then
  ok "certificates look quiet (none ends within ${WARN_DAYS} days)"
  exit 4
fi
info "${FINDINGS} finding(s)"
exit 0
