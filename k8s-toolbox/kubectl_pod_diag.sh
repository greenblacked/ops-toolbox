#!/usr/bin/env bash
# kubectl_pod_diag.sh
# Read-only cluster triage: non-Running pods, Warning events, CrashLoopBackOff
# previous logs, unbound PVCs, and node pressure conditions.
#
# Usage:
#   ./kubectl_pod_diag.sh [--namespace NS] [--context CTX] [--all-namespaces]
#
# Exit codes:
#   0 findings reported (or cluster healthy after listing)
#   1 kubectl failed
#   2 kubectl missing / cannot reach cluster
#   3 bad arguments
#   4 nothing to report
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
$(basename "$0") - read-only Kubernetes cluster triage

Usage:
  $(basename "$0") [--namespace NS] [--context CTX] [--all-namespaces]

Options:
  --namespace NS, -n NS   Limit pod/event/PVC checks to one namespace
  --all-namespaces, -A    Scan every namespace (default when -n is omitted)
  --context CTX           kubectl context
  -h, --help              Show this help

Exit codes: 0 reported findings or healthy summary, 1 kubectl error,
            2 wrong environment, 3 usage, 4 nothing to report
EOF
}

NAMESPACE=""
CONTEXT=""
ALL_NS=1
KUBECTL=(kubectl)
FINDINGS=0

while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -n|--namespace) require_value "$1" "${2:-}"; NAMESPACE="$2"; ALL_NS=0; shift ;;
    --namespace=*) NAMESPACE="${1#*=}"; require_value "--namespace" "$NAMESPACE"; ALL_NS=0 ;;
    -A|--all-namespaces) ALL_NS=1; NAMESPACE="" ;;
    --context) require_value "$1" "${2:-}"; CONTEXT="$2"; shift ;;
    --context=*) CONTEXT="${1#*=}"; require_value "--context" "$CONTEXT" ;;
    *)
      err "unknown option: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

if ! command -v kubectl >/dev/null 2>&1; then
  err "kubectl is not installed or not on PATH"
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

section "Non-Running pods"
pod_json="$("${KUBECTL[@]}" get pods "${ns_args[@]}" -o json 2>/dev/null || true)"
if [[ -z "$pod_json" ]]; then
  warn "could not list pods"
  FINDINGS=$((FINDINGS + 1))
else
  bad_pods="$(printf '%s' "$pod_json" | python3 -c '
import json,sys
doc=json.load(sys.stdin)
items=doc.get("items") or []
rows=[]
for p in items:
  phase=(p.get("status") or {}).get("phase","")
  if phase in ("Running","Succeeded"):
    # Still surface CrashLoopBackOff containers on Running pods.
    bad=False
    for cs in (p.get("status") or {}).get("containerStatuses") or []:
      waiting=((cs.get("state") or {}).get("waiting") or {})
      if waiting.get("reason") in ("CrashLoopBackOff","ImagePullBackOff","ErrImagePull"):
        bad=True
        break
    if not bad:
      continue
  ns=p.get("metadata",{}).get("namespace","")
  name=p.get("metadata",{}).get("name","")
  reason=phase
  for cs in (p.get("status") or {}).get("containerStatuses") or []:
    waiting=((cs.get("state") or {}).get("waiting") or {})
    if waiting.get("reason"):
      reason=waiting["reason"]
      break
  rows.append("%s\t%s\t%s" % (ns, name, reason))
print("\n".join(rows))
')"
  if [[ -z "$bad_pods" ]]; then
    ok "no unhealthy pods"
  else
    while IFS=$'\t' read -r ns name reason; do
      [[ -n "$ns" ]] || continue
      warn "pod ${ns}/${name}: ${reason}"
      FINDINGS=$((FINDINGS + 1))
      if [[ "$reason" == "CrashLoopBackOff" ]]; then
        info "previous logs for ${ns}/${name}:"
        "${KUBECTL[@]}" logs -n "$ns" "$name" --previous --tail=40 2>/dev/null \
          | sed 's/^/    /' || warn "  (no previous logs)"
      fi
    done <<<"$bad_pods"
  fi
fi

section "Warning events (last hour)"
event_json="$("${KUBECTL[@]}" get events "${ns_args[@]}" --field-selector type=Warning -o json 2>/dev/null || true)"
if [[ -z "$event_json" ]]; then
  warn "could not list events"
  FINDINGS=$((FINDINGS + 1))
else
  warns="$(printf '%s' "$event_json" | python3 -c '
import json,sys,datetime
doc=json.load(sys.stdin)
now=datetime.datetime.now(datetime.timezone.utc)
cutoff=now-datetime.timedelta(hours=1)
rows=[]
for e in doc.get("items") or []:
  ts=e.get("lastTimestamp") or e.get("eventTime") or e.get("metadata",{}).get("creationTimestamp")
  if not ts:
    continue
  try:
    when=datetime.datetime.fromisoformat(ts.replace("Z","+00:00"))
  except ValueError:
    continue
  if when < cutoff:
    continue
  ns=e.get("metadata",{}).get("namespace","")
  name=(e.get("involvedObject") or {}).get("name","")
  reason=e.get("reason","")
  msg=(e.get("message") or "").replace("\n"," ")
  rows.append("%s\t%s\t%s\t%s" % (ns, name, reason, msg[:120]))
print("\n".join(rows[:40]))
')"
  if [[ -z "$warns" ]]; then
    ok "no recent Warning events"
  else
    while IFS=$'\t' read -r ns name reason msg; do
      [[ -n "$reason" ]] || continue
      warn "event ${ns}/${name}: ${reason} — ${msg}"
      FINDINGS=$((FINDINGS + 1))
    done <<<"$warns"
  fi
fi

section "Unbound PVCs"
pvc_json="$("${KUBECTL[@]}" get pvc "${ns_args[@]}" -o json 2>/dev/null || true)"
if [[ -z "$pvc_json" ]]; then
  warn "could not list PVCs"
  FINDINGS=$((FINDINGS + 1))
else
  unbound="$(printf '%s' "$pvc_json" | python3 -c '
import json,sys
doc=json.load(sys.stdin)
rows=[]
for p in doc.get("items") or []:
  phase=(p.get("status") or {}).get("phase","")
  if phase == "Bound":
    continue
  ns=p.get("metadata",{}).get("namespace","")
  name=p.get("metadata",{}).get("name","")
  rows.append("%s\t%s\t%s" % (ns, name, phase or "?"))
print("\n".join(rows))
')"
  if [[ -z "$unbound" ]]; then
    ok "no unbound PVCs"
  else
    while IFS=$'\t' read -r ns name phase; do
      [[ -n "$ns" ]] || continue
      warn "pvc ${ns}/${name}: ${phase}"
      FINDINGS=$((FINDINGS + 1))
    done <<<"$unbound"
  fi
fi

section "Node pressure"
node_json="$("${KUBECTL[@]}" get nodes -o json 2>/dev/null || true)"
if [[ -z "$node_json" ]]; then
  warn "could not list nodes"
  FINDINGS=$((FINDINGS + 1))
else
  pressure="$(printf '%s' "$node_json" | python3 -c '
import json,sys
doc=json.load(sys.stdin)
rows=[]
for n in doc.get("items") or []:
  name=n.get("metadata",{}).get("name","")
  for c in (n.get("status") or {}).get("conditions") or []:
    ctype=c.get("type","")
    status=c.get("status","")
    if ctype in ("MemoryPressure","DiskPressure","PIDPressure") and status == "True":
      rows.append("%s\t%s\t%s" % (name, ctype, c.get("message","")[:100]))
    if ctype == "Ready" and status != "True":
      rows.append("%s\tReady=%s\t%s" % (name, status, c.get("reason","")))
print("\n".join(rows))
')"
  if [[ -z "$pressure" ]]; then
    ok "no node pressure conditions"
  else
    while IFS=$'\t' read -r name ctype msg; do
      [[ -n "$name" ]] || continue
      warn "node ${name}: ${ctype} — ${msg}"
      FINDINGS=$((FINDINGS + 1))
    done <<<"$pressure"
  fi
fi

printf "\n"
if (( FINDINGS == 0 )); then
  ok "cluster looks quiet"
  exit 4
fi
info "${FINDINGS} finding(s)"
exit 0
