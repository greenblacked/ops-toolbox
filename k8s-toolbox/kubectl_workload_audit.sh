#!/usr/bin/env bash
# kubectl_workload_audit.sh
# Read-only pod-template hygiene audit across Deployments, StatefulSets,
# DaemonSets and CronJobs: requests and memory limits, readiness probes,
# image tags, security context, replicas and disruption budgets. Prints a fix
# per check; never changes a workload.
#
# Usage:
#   ./kubectl_workload_audit.sh [--namespace NS] [--context CTX] [--all-namespaces]
#                               [--only CHECK[,CHECK...]] [--list-checks]
#                               [--include-system] [--limit N]
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

CHECKS=(
  "resources|cpu and memory requests, memory limit"
  "probes|readinessProbe on Deployment and StatefulSet containers"
  "image-tag|images pinned to a tag or digest, not latest"
  "security|privileged, host namespaces, hostPath, root, privilege escalation"
  "availability|single-replica Deployments, replicated workloads without a PDB"
)

check_ids() {
  local row
  for row in "${CHECKS[@]}"; do
    printf '%s\n' "${row%%|*}"
  done
}

usage() {
  cat <<EOF
$(basename "$0") - read-only audit of workload pod templates

Usage:
  $(basename "$0") [--namespace NS] [--context CTX] [--all-namespaces]
                  [--only CHECK[,CHECK...]] [--list-checks]
                  [--include-system] [--limit N]

Reads the pod templates of Deployments, StatefulSets, DaemonSets and CronJobs
and reports what reviewers raise by hand: containers with no requests or no
memory limit, no readiness probe, untagged or latest images, privileged or
host-namespace pods, hostPath volumes, containers that may run as root or
escalate privileges, single-replica Deployments, and replicated workloads no
PodDisruptionBudget covers. Each finding is labelled [risk] or [advice], and
each check ends with a fix line that is printed, never run.

Options:
  --namespace NS, -n NS   Limit the audit to one namespace
  --all-namespaces, -A    Audit every namespace (default when -n is omitted)
  --context CTX           kubectl context
  --only LIST             Only the named checks (see --list-checks)
  --list-checks           Print stable check ids and exit
  --include-system        Also audit kube-system, kube-public,
                          kube-node-lease and gke-*/gmp-* namespaces
  --limit N               Print at most N findings per check (default: 40)
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
INCLUDE_SYSTEM=0
LIMIT=40

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
    --include-system) INCLUDE_SYSTEM=1 ;;
    --limit) require_value "$1" "${2:-}"; LIMIT="$2"; shift ;;
    --limit=*) LIMIT="${1#*=}"; require_value "--limit" "$LIMIT" ;;
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

if ! [[ "$LIMIT" =~ ^[1-9][0-9]*$ ]]; then
  err "--limit must be a positive whole number (for example 40)"
  exit 3
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
  local needle s
  for needle in "$@"; do
    for s in "${SELECTED[@]}"; do
      [[ "$s" == "$needle" ]] && return 0
    done
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

# A fix that is a kubectl command names the context this run read, so pasting
# it cannot change a workload of the same name in another cluster.
fix_step() {
  local cmd="$1"
  if [[ -n "$CONTEXT" && "$cmd" == "kubectl "* ]]; then
    cmd="kubectl --context $(printf '%q' "$CONTEXT") ${cmd#kubectl }"
  fi
  info "fix       $cmd"
}

CHECK_ERRORS=0
FETCHED=""

# fetch RESOURCE: one read-only get per kind into FETCHED, so a Forbidden on
# one kind costs that kind only. A failed or empty answer is counted and
# leaves FETCHED empty, which the filter skips.
fetch() {
  local resource="$1" rc=0
  FETCHED="$("${KUBECTL[@]}" get "$resource" "${ns_args[@]}" -o json 2>/dev/null)" || rc=$?
  if (( rc != 0 )) || [[ -z "$FETCHED" ]]; then
    warn "could not list $resource"
    CHECK_ERRORS=$((CHECK_ERRORS + 1))
    FETCHED=""
  fi
}

# Only the kinds the selected checks read are listed: probes and availability
# apply to Deployments and StatefulSets alone, and only availability needs
# the PodDisruptionBudgets.
section "Workloads"
deploy_json=""; sts_json=""; ds_json=""; cj_json=""; pdb_json=""
fetch deployments; deploy_json="$FETCHED"
fetch statefulsets; sts_json="$FETCHED"
if want resources image-tag security; then
  fetch daemonsets; ds_json="$FETCHED"
  fetch cronjobs; cj_json="$FETCHED"
fi
if want availability; then
  fetch pdb; pdb_json="$FETCHED"
fi
FETCHED=""
selected_csv="$(IFS=','; printf '%s' "${SELECTED[*]}")"
info "checks    ${selected_csv//,/, }"
if (( INCLUDE_SYSTEM == 0 )); then
  info "skipping  kube-system, kube-public, kube-node-lease, gke-*, gmp-* (--include-system to audit them)"
fi

# The documents travel on one pipe, split by the ASCII record separator,
# which valid JSON cannot contain unescaped.
RS=$'\x1e'
if ! report="$(printf '%s%s%s%s%s%s%s%s%s' "$deploy_json" "$RS" "$sts_json" "$RS" "$ds_json" "$RS" "$cj_json" "$RS" "$pdb_json" | python3 -c '
import json,sys
checks=sys.argv[1].split(",")
limit=int(sys.argv[2])
include_system=sys.argv[3] == "1"
parts=sys.stdin.read().split("\x1e")
if len(parts) != 5:
  raise ValueError("expected five documents")
out=[]
def load(raw,what):
  # An empty part is a query that already failed (and was counted) or one
  # this selection did not need.
  if not raw.strip():
    return None
  try:
    items=json.loads(raw)["items"]
    if not isinstance(items,list) or any(not isinstance(i,dict) for i in items):
      raise ValueError("expected a Kubernetes items list")
    for i in items:
      if not (i.get("metadata") or {}).get("name"):
        raise ValueError("every item needs a name")
    return items
  except (ValueError,KeyError,TypeError):
    out.append("E\t"+what)
    return None
SYSTEM=("kube-system","kube-public","kube-node-lease")
workloads=[]
for (kind,plural),raw in zip((("deployment","deployments"),("statefulset","statefulsets"),
                              ("daemonset","daemonsets"),("cronjob","cronjobs")),parts[:4]):
  for w in load(raw,plural) or []:
    meta=w["metadata"]
    ns=meta.get("namespace","")
    if not include_system and (ns in SYSTEM or ns.startswith("gke-") or ns.startswith("gmp-")):
      continue
    spec=w.get("spec") or {}
    if kind == "cronjob":
      template=((spec.get("jobTemplate") or {}).get("spec") or {}).get("template") or {}
    else:
      template=spec.get("template") or {}
    workloads.append((kind,ns,meta["name"],spec,template))
pdbs=load(parts[4],"PodDisruptionBudgets")
def matches(selector,labels):
  # policy/v1: an empty selector matches every pod in the namespace, a
  # missing one matches none.
  if selector is None:
    return False
  if not isinstance(selector,dict):
    raise ValueError("selector must be an object")
  for key,value in (selector.get("matchLabels") or {}).items():
    if labels.get(key) != value:
      return False
  for e in selector.get("matchExpressions") or []:
    key=e.get("key")
    op=e.get("operator")
    values=e.get("values") or []
    if op == "In":
      if key not in labels or labels[key] not in values:
        return False
    elif op == "NotIn":
      if key in labels and labels[key] in values:
        return False
    elif op == "Exists":
      if key not in labels:
        return False
    elif op == "DoesNotExist":
      if key in labels:
        return False
    else:
      raise ValueError("unknown selector operator")
  return True
def containers(template,init=False):
  pod=template.get("spec") or {}
  found=list(pod.get("containers") or [])
  if init:
    found+=list(pod.get("initContainers") or [])
  return found
def image_problem(image):
  # A registry port is not a tag: only the last path segment can carry one.
  if "@" in image:
    return None
  last=image.rsplit("/",1)[-1]
  if ":" not in last:
    return "runs untagged image %s" % image
  if last.split(":",1)[1] == "latest":
    return "runs %s" % image
  return None
def where(kind,ns,name):
  return "%s %s/%s" % (kind,ns,name)
rows={c:[] for c in checks}
for kind,ns,name,spec,template in workloads:
  ref="%s/%s -n %s" % (kind,name,ns)
  pod=template.get("spec") or {}
  if "resources" in rows:
    for c in containers(template):
      res=c.get("resources") or {}
      req=res.get("requests") or {}
      lim=res.get("limits") or {}
      # A limit with no request makes the request equal to the limit.
      missing=[]
      if "cpu" not in req and "cpu" not in lim:
        missing.append("no cpu request")
      if "memory" not in req and "memory" not in lim:
        missing.append("no memory request")
      if "memory" not in lim:
        missing.append("no memory limit")
      if missing:
        rows["resources"].append(("risk" if "memory" not in lim else "advice",
          "%s: container %s has %s" % (where(kind,ns,name),c.get("name",""),", ".join(missing)),
          "kubectl set resources %s -c %s --requests=cpu=100m,memory=128Mi --limits=memory=256Mi" % (ref,c.get("name",""))))
  if "probes" in rows and kind in ("deployment","statefulset"):
    for c in containers(template):
      if not c.get("readinessProbe"):
        rows["probes"].append(("advice","%s: container %s has no readinessProbe" % (where(kind,ns,name),c.get("name","")),
          "add readinessProbe (for example httpGet on /healthz) to container %s in %s %s/%s, then apply the manifest" % (c.get("name",""),kind,ns,name)))
  if "image-tag" in rows:
    for c in containers(template,True):
      problem=image_problem(str(c.get("image") or ""))
      if problem:
        rows["image-tag"].append(("advice","%s: container %s %s" % (where(kind,ns,name),c.get("name",""),problem),
          "kubectl set image %s %s=REPOSITORY:VERSION (or REPOSITORY@sha256:DIGEST)" % (ref,c.get("name",""))))
  if "security" in rows:
    pod_sc=pod.get("securityContext") or {}
    host=[flag for flag in ("hostNetwork","hostPID","hostIPC") if pod.get(flag) is True]
    host+=["hostPath %s" % ((v.get("hostPath") or {}).get("path") or v.get("name","")) for v in pod.get("volumes") or [] if "hostPath" in v]
    fix="set runAsNonRoot: true and allowPrivilegeEscalation: false in %s %s/%s; drop privileged, host namespaces and hostPath unless it truly needs them" % (kind,ns,name)
    if host:
      rows["security"].append(("risk","%s: pod uses %s" % (where(kind,ns,name),", ".join(host)),fix))
    for c in containers(template,True):
      sc=c.get("securityContext") or {}
      issues=[]
      risk=False
      if sc.get("privileged") is True:
        issues.append("privileged")
        risk=True
      if sc.get("allowPrivilegeEscalation") is not False:
        issues.append("allowPrivilegeEscalation not false")
      if sc.get("runAsNonRoot") is not True and pod_sc.get("runAsNonRoot") is not True:
        issues.append("runAsNonRoot unset")
      if issues:
        rows["security"].append(("risk" if risk else "advice",
          "%s: container %s: %s" % (where(kind,ns,name),c.get("name",""),", ".join(issues)),fix))
  if "availability" in rows and kind in ("deployment","statefulset"):
    replicas=spec.get("replicas",1)
    if isinstance(replicas,bool) or not isinstance(replicas,int):
      raise ValueError("replicas must be an integer")
    if kind == "deployment" and replicas == 1:
      rows["availability"].append(("advice","%s: 1 replica, so any restart or node drain is an outage" % where(kind,ns,name),
        "kubectl scale %s --replicas=2" % ref))
    elif replicas >= 2 and pdbs is not None:
      labels=(template.get("metadata") or {}).get("labels") or {}
      covered=[b for b in pdbs if (b.get("metadata") or {}).get("namespace") == ns
               and matches((b.get("spec") or {}).get("selector"),labels)]
      if not covered:
        selector=",".join("%s=%s" % kv for kv in sorted(((spec.get("selector") or {}).get("matchLabels") or {}).items())) or "KEY=VALUE"
        rows["availability"].append(("advice","%s: %d replicas and no PodDisruptionBudget, so a drain may take them all at once" % (where(kind,ns,name),replicas),
          "kubectl create poddisruptionbudget %s -n %s --selector=%s --min-available=1 --dry-run=client -o yaml" % (name,ns,selector)))
HEADINGS={"resources":("Resources: requests and memory limits","every container sets cpu and memory requests and a memory limit"),
          "probes":("Probes: readiness","every Deployment and StatefulSet container has a readinessProbe"),
          "image-tag":("Image tags","every image is pinned to a tag or digest other than latest"),
          "security":("Security context","no privileged, host-namespace or hostPath pods, and every container runs as non-root without privilege escalation"),
          "availability":("Availability: replicas and disruption budgets","no single-replica Deployment and every replicated workload has a PodDisruptionBudget")}
for check in checks:
  out.append("S\t"+HEADINGS[check][0])
  found=rows[check]
  for label,text,_ in found[:limit]:
    out.append("F\t[%s] %s" % (label,text))
  if len(found) > limit:
    out.append("M\t%d" % (len(found)-limit))
  if found:
    out.append("X\t"+found[0][2])
  else:
    out.append("Q\t"+HEADINGS[check][1])
print("\n".join(out))
' "$selected_csv" "$LIMIT" "$INCLUDE_SYSTEM" 2>/dev/null)"; then
  warn "could not parse the workload templates"
  CHECK_ERRORS=$((CHECK_ERRORS + 1))
  report=""
fi

while IFS=$'\t' read -r tag text; do
  [[ -n "$tag" ]] || continue
  case "$tag" in
    S) section "$text" ;;
    Q) ok "$text" ;;
    F) warn "$text"; FINDINGS=$((FINDINGS + 1)) ;;
    M)
      if [[ "$text" =~ ^[0-9]+$ ]]; then
        info "... and $text more (raise --limit)"
        FINDINGS=$((FINDINGS + text))
      fi
      ;;
    X) fix_step "$text" ;;
    E) warn "could not parse $text JSON"; CHECK_ERRORS=$((CHECK_ERRORS + 1)) ;;
  esac
done <<<"$report"

printf "\n"
if (( CHECK_ERRORS > 0 )); then
  err "${CHECK_ERRORS} query or JSON parsing check(s) failed; audit incomplete"
  exit 1
fi
if (( FINDINGS == 0 )); then
  ok "workload audit looks quiet"
  exit 4
fi
info "${FINDINGS} finding(s)"
exit 0
