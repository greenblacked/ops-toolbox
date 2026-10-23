#!/usr/bin/env bash
# kubectl_workload_diag.sh
# Read-only workload triage: stuck Deployment rollouts, StatefulSet and
# DaemonSet updates, HorizontalPodAutoscalers that cannot scale, failed Jobs.
# Prints the kubectl command to look further for each finding; never runs it.
#
# Usage:
#   ./kubectl_workload_diag.sh [--namespace NS] [--context CTX] [--all-namespaces]
#                              [--only CHECK[,CHECK...]] [--list-checks]
#
# Exit codes:
#   0 findings reported
#   1 query or JSON parsing failed
#   2 kubectl or python3 missing / cannot reach cluster
#   3 bad arguments (including an unknown or empty --only)
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

# id|kubectl resource|section heading|quiet message
CHECKS=(
  "deployments|deployments|Deployments|no stuck Deployment rollouts"
  "statefulsets|statefulsets|StatefulSets|no stuck StatefulSets"
  "daemonsets|daemonsets|DaemonSets|no DaemonSets with unavailable or misscheduled pods"
  "hpa|hpa|HorizontalPodAutoscalers|no autoscalers failing or pinned at maxReplicas"
  "jobs|jobs|Jobs|no failed Jobs"
)

check_ids() {
  local row
  for row in "${CHECKS[@]}"; do
    printf '%s\n' "${row%%|*}"
  done
}

usage() {
  cat <<EOF
$(basename "$0") - read-only triage of stuck rollouts, autoscalers and Jobs

Usage:
  $(basename "$0") [--namespace NS] [--context CTX] [--all-namespaces]
                  [--only CHECK[,CHECK...]] [--list-checks]

Reports Deployments past their progress deadline, paused, unavailable or
not yet observed by the controller; StatefulSets not ready or stuck mid-update;
DaemonSets with unavailable or misscheduled pods; autoscalers that cannot read
metrics, cannot scale, or sit at maxReplicas; and Jobs that failed. Each
finding is followed by the kubectl command to look further, printed and never
run.

Options:
  --namespace NS, -n NS   Limit every check to one namespace
  --all-namespaces, -A    Scan every namespace (default when -n is omitted)
  --context CTX           kubectl context
  --only LIST             Only the named checks (see --list-checks)
  --list-checks           Print stable check ids and exit
  -h, --help              Show this help

Exit codes: 0 reported findings, 1 query or JSON parsing error,
            2 wrong environment, 3 usage (also an unknown or empty --only),
            4 nothing to report
EOF
}

NAMESPACE=""
CONTEXT=""
ALL_NS=1
KUBECTL=(kubectl)
FINDINGS=0
ONLY=""
LIST_CHECKS=0

while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --list-checks) LIST_CHECKS=1 ;;
    -n|--namespace) require_value "$1" "${2:-}"; NAMESPACE="$2"; ALL_NS=0; shift ;;
    --namespace=*) NAMESPACE="${1#*=}"; require_value "--namespace" "$NAMESPACE"; ALL_NS=0 ;;
    -A|--all-namespaces) ALL_NS=1; NAMESPACE="" ;;
    --context) require_value "$1" "${2:-}"; CONTEXT="$2"; shift ;;
    --context=*) CONTEXT="${1#*=}"; require_value "--context" "$CONTEXT" ;;
    --only) require_value "$1" "${2:-}"; ONLY="$2"; shift ;;
    --only=*) ONLY="${1#*=}"; require_value "--only" "$ONLY" ;;
    *)
      err "unknown option: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

if (( LIST_CHECKS )); then
  check_ids
  exit 0
fi

# Unlike gke_cluster_doctor.sh, an empty selection is a usage error here:
# exit 4 already means "every check ran and found nothing".
SELECTED=()
known=" "
row=""
for row in "${CHECKS[@]}"; do
  known="$known ${row%%|*} "
done
if [[ -n "$ONLY" ]]; then
  IFS=',' read -r -a items <<< "$ONLY"
  for raw in "${items[@]}"; do
    id="$(printf '%s' "$raw" | tr -d '[:space:]')"
    [[ -n "$id" ]] || continue
    case "$known" in
      *" $id "*) SELECTED+=("$id") ;;
      *) err "unknown check in --only: $id (see --list-checks)"; exit 3 ;;
    esac
  done
  if (( ${#SELECTED[@]} == 0 )); then
    err "--only selected nothing (see --list-checks)"
    exit 3
  fi
else
  for row in "${CHECKS[@]}"; do
    SELECTED+=("${row%%|*}")
  done
fi

want() {
  local needle="$1" s
  for s in "${SELECTED[@]}"; do
    [[ "$s" == "$needle" ]] && return 0
  done
  return 1
}

if ! command -v kubectl >/dev/null 2>&1; then
  err "kubectl is not installed or not on PATH"
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  err "python3 is not installed or not on PATH"
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

# One get per kind, so a Forbidden on one resource costs that section only.
check_kind() {
  local id="$1" resource="$2" title="$3" quiet="$4"
  local doc="" rc=0 rows="" tag text
  section "$title"
  doc="$("${KUBECTL[@]}" get "$resource" "${ns_args[@]}" -o json 2>/dev/null)" || rc=$?
  if (( rc != 0 )) || [[ -z "$doc" ]]; then
    warn "could not list $resource"
    CHECK_ERRORS=$((CHECK_ERRORS + 1))
    return 0
  fi
  if ! rows="$(printf '%s' "$doc" | python3 -c '
import json,sys
check=sys.argv[1]
doc=json.load(sys.stdin)
items=doc["items"]
if not isinstance(items,list) or any(not isinstance(i,dict) for i in items):
  raise ValueError("expected a Kubernetes items list")
def count(obj,key,default=0):
  value=(obj or {}).get(key)
  if value is None:
    return default
  if isinstance(value,bool) or not isinstance(value,int):
    raise ValueError("%s must be an integer" % key)
  return value
def conditions(status):
  found={}
  for c in status.get("conditions") or []:
    if not isinstance(c,dict):
      raise ValueError("conditions must be objects")
    found[c.get("type","")]=c
  return found
def clean(text):
  return " ".join(str(text or "").split())[:100]
rows=[]
for item in items:
  meta=item.get("metadata") or {}
  ns=meta.get("namespace","")
  name=meta.get("name","")
  if not ns or not name:
    raise ValueError("metadata must identify namespace and name")
  spec=item.get("spec") or {}
  status=item.get("status") or {}
  cond=conditions(status)
  found=[]
  nexts=[]
  if check == "deployments":
    label="deployment"
    want=count(spec,"replicas",1)
    if want == 0:
      continue
    available=count(status,"availableReplicas")
    nexts.append("kubectl rollout status deployment/%s -n %s" % (name,ns))
    progressing=cond.get("Progressing") or {}
    if progressing.get("reason") == "ProgressDeadlineExceeded" or progressing.get("status") == "False":
      found.append(progressing.get("reason") or "Progressing=False")
      nexts.append("kubectl rollout undo deployment/%s -n %s" % (name,ns))
    if spec.get("paused") is True:
      found.append("rollout paused")
      nexts.append("kubectl rollout resume deployment/%s -n %s" % (name,ns))
    generation=count(meta,"generation")
    observed=count(status,"observedGeneration")
    if observed < generation:
      found.append("spec generation %d not observed yet, controller at %d" % (generation,observed))
    if available < want and not found:
      found.append("replicas unavailable")
    if found:
      found[-1]+=" (%d/%d available)" % (available,want)
  elif check == "statefulsets":
    label="statefulset"
    want=count(spec,"replicas",1)
    ready=count(status,"readyReplicas")
    updated=count(status,"updatedReplicas")
    rolling=(spec.get("updateStrategy") or {}).get("rollingUpdate") or {}
    partition=count(rolling,"partition")
    first=count(spec.get("ordinals"),"start")
    if ready < want:
      found.append("%d/%d ready" % (ready,want))
    target=status.get("updateRevision") or ""
    current=status.get("currentRevision") or ""
    # OnDelete keeps currentRevision behind updateRevision by design, and a
    # partition only asks for the ordinals at or above it to be updated. It
    # is an absolute ordinal, and the pods run from spec.ordinals.start.
    strategy=(spec.get("updateStrategy") or {}).get("type") or "RollingUpdate"
    expected=max(first+want-max(partition,first),0)
    if strategy == "RollingUpdate" and target and current and target != current and updated < expected:
      found.append("update to %s stuck (%d/%d updated)" % (target,updated,expected))
    nexts.append("kubectl rollout status statefulset/%s -n %s" % (name,ns))
  elif check == "daemonsets":
    label="daemonset"
    desired=count(status,"desiredNumberScheduled")
    ready=count(status,"numberReady")
    unavailable=count(status,"numberUnavailable")
    misscheduled=count(status,"numberMisscheduled")
    if ready < desired or unavailable > 0:
      found.append("%d/%d ready, %d unavailable" % (ready,desired,unavailable))
      nexts.append("kubectl rollout status daemonset/%s -n %s" % (name,ns))
    if misscheduled > 0:
      found.append("%d misscheduled" % misscheduled)
      nexts.append("kubectl describe daemonset %s -n %s" % (name,ns))
  elif check == "hpa":
    label="hpa"
    # ScalingDisabled is what an autoscaler reports while its target is
    # scaled to zero on purpose, so it is not a fault.
    for ctype in ("ScalingActive","AbleToScale"):
      c=cond.get(ctype) or {}
      if c.get("status") == "False" and c.get("reason") != "ScalingDisabled":
        found.append("%s=False %s: %s" % (ctype,c.get("reason") or "Unknown",clean(c.get("message"))))
    maximum=count(spec,"maxReplicas")
    current=count(status,"currentReplicas")
    if maximum > 0 and current >= maximum:
      found.append("at max %d" % maximum)
    nexts.append("kubectl describe hpa %s -n %s" % (name,ns))
  elif check == "jobs":
    label="job"
    if meta.get("deletionTimestamp"):
      continue
    if (cond.get("Complete") or {}).get("status") == "True":
      continue
    failed=cond.get("Failed") or {}
    if failed.get("status") == "True":
      found.append("%s (%d failed pod(s))" % (failed.get("reason") or "Failed",count(status,"failed")))
    nexts.append("kubectl describe job %s -n %s" % (name,ns))
  else:
    raise ValueError("unknown check")
  if found:
    rows.append("F\t%s %s/%s: %s" % (label,ns,name,"; ".join(found)))
    rows.extend("N\t%s" % n for n in nexts)
print("\n".join(rows))
' "$id" 2>/dev/null)"; then
    warn "could not parse $resource JSON"
    CHECK_ERRORS=$((CHECK_ERRORS + 1))
    return 0
  fi
  if [[ -z "$rows" ]]; then
    ok "$quiet"
    return 0
  fi
  while IFS=$'\t' read -r tag text; do
    [[ -n "$text" ]] || continue
    if [[ "$tag" == "F" ]]; then
      warn "$text"
      FINDINGS=$((FINDINGS + 1))
    else
      next_step "$text"
    fi
  done <<<"$rows"
}

for row in "${CHECKS[@]}"; do
  IFS='|' read -r id resource title quiet <<<"$row"
  want "$id" || continue
  check_kind "$id" "$resource" "$title" "$quiet"
done

printf "\n"
if (( CHECK_ERRORS > 0 )); then
  err "${CHECK_ERRORS} query or JSON parsing check(s) failed; workload check incomplete"
  exit 1
fi
if (( FINDINGS == 0 )); then
  ok "workloads look quiet"
  exit 4
fi
info "${FINDINGS} finding(s)"
exit 0
