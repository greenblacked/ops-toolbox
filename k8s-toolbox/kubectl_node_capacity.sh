#!/usr/bin/env bash
# kubectl_node_capacity.sh
# Read-only per-node capacity report: CPU, memory and pod requests against
# allocatable, the way the scheduler adds them up. No metrics-server needed.
# Also lists pods the scheduler could not place.
#
# Usage:
#   ./kubectl_node_capacity.sh [--context CTX] [--threshold PCT]
#
# Exit codes:
#   0 findings reported
#   1 query or JSON parsing failed
#   2 kubectl or python3 missing / cannot reach cluster
#   3 bad arguments
#   4 nothing at or above the threshold and nothing pending
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
$(basename "$0") - read-only node capacity: requests against allocatable

Usage:
  $(basename "$0") [--context CTX] [--threshold PCT]

Adds up the CPU, memory and pod-count requests of every scheduled, unfinished
pod per node, the way the scheduler does (init and sidecar containers and pod
overhead included), and sets them against each node's allocatable. A node at
or above the threshold on any of the three, or NotReady, is a finding, and so
is a pod the scheduler marked Unschedulable. These are requests, not live
usage: kubectl top answers a different question and needs metrics-server.
Capacity is a node property, so the report is always cluster-wide.

Options:
  --context CTX           kubectl context
  --threshold PCT         Report nodes at or above PCT percent (1-100,
                          default: 85)
  -h, --help              Show this help

Exit codes: 0 reported findings, 1 query or JSON parsing error,
            2 wrong environment, 3 usage,
            4 nothing at or above the threshold and nothing pending
EOF
}

CONTEXT=""
KUBECTL=(kubectl)
FINDINGS=0
THRESHOLD=85

while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --context) require_value "$1" "${2:-}"; CONTEXT="$2"; shift ;;
    --context=*) CONTEXT="${1#*=}"; require_value "--context" "$CONTEXT" ;;
    --threshold) require_value "$1" "${2:-}"; THRESHOLD="$2"; shift ;;
    --threshold=*) THRESHOLD="${1#*=}"; require_value "--threshold" "$THRESHOLD" ;;
    *)
      err "unknown option: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

if ! [[ "$THRESHOLD" =~ ^[1-9][0-9]?$ || "$THRESHOLD" == "100" ]]; then
  err "--threshold must be a whole percentage from 1 to 100 (for example 85)"
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

if [[ -n "$CONTEXT" ]]; then
  KUBECTL+=(--context "$CONTEXT")
fi

if ! "${KUBECTL[@]}" cluster-info >/dev/null 2>&1; then
  err "cannot reach the cluster (check kubeconfig / context)"
  exit 2
fi

section() { printf "\n%s== %s ==%s\n" "$C_BOLD" "$*" "$C_RESET"; }

CHECK_ERRORS=0
FETCHED=""

# fetch WHAT ARGS...: one read-only get into FETCHED; a failed or empty
# answer is counted and leaves FETCHED empty, which the filter skips.
fetch() {
  local what="$1" rc=0
  shift
  FETCHED="$("${KUBECTL[@]}" get "$@" -o json 2>/dev/null)" || rc=$?
  if (( rc != 0 )) || [[ -z "$FETCHED" ]]; then
    warn "could not $what"
    CHECK_ERRORS=$((CHECK_ERRORS + 1))
    FETCHED=""
  fi
}

section "Nodes (requests against allocatable, threshold ${THRESHOLD}%)"
fetch "list nodes" nodes
node_json="$FETCHED"
fetch "list pods" pods --all-namespaces
pod_json="$FETCHED"
FETCHED=""

# Both documents travel on one pipe, split by the ASCII record separator,
# which valid JSON cannot contain unescaped.
RS=$'\x1e'
if ! report="$(printf '%s%s%s' "$node_json" "$RS" "$pod_json" | python3 -c '
import json,re,sys
from fractions import Fraction
threshold=int(sys.argv[1])
parts=sys.stdin.read().split("\x1e")
if len(parts) != 2:
  raise ValueError("expected two documents")
out=[]
def load(raw,what):
  # An empty part is a query that already failed and was counted.
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
nodes=load(parts[0],"nodes")
pods=load(parts[1],"pods")
SUFFIX={"":1,"n":Fraction(1,10**9),"u":Fraction(1,10**6),"m":Fraction(1,1000),
        "k":10**3,"M":10**6,"G":10**9,"T":10**12,"P":10**15,"E":10**18,
        "Ki":2**10,"Mi":2**20,"Gi":2**30,"Ti":2**40,"Pi":2**50,"Ei":2**60}
QUANTITY=re.compile(r"([0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE]([+-]?[0-9]+))?(Ki|Mi|Gi|Ti|Pi|Ei|n|u|m|k|M|G|T|P|E)?")
def quantity(text):
  # Every form the API serialises: 250m, 0.5, 2, 1500Mi, 2Gi, 1G, 129e6, 100k.
  match=QUANTITY.fullmatch(str(text).strip())
  if not match:
    raise ValueError("not a Kubernetes quantity")
  value=Fraction(match.group(1))
  if match.group(2):
    value*=Fraction(10)**int(match.group(2))
  return value*SUFFIX[match.group(3) or ""]
def requests(container):
  req=(container.get("resources") or {}).get("requests") or {}
  return (quantity(req["cpu"])*1000 if "cpu" in req else Fraction(0),
          quantity(req["memory"]) if "memory" in req else Fraction(0))
def add(a,b):
  return (a[0]+b[0],a[1]+b[1])
def pod_request(spec):
  # The scheduler formula: app containers run beside every restartable
  # (sidecar) init container; each ordinary init container runs alone with
  # the sidecars started before it; the larger wins, plus pod overhead.
  apps=(Fraction(0),Fraction(0))
  for c in spec.get("containers") or []:
    apps=add(apps,requests(c))
  sidecars=(Fraction(0),Fraction(0))
  peak=(Fraction(0),Fraction(0))
  for c in spec.get("initContainers") or []:
    r=requests(c)
    if c.get("restartPolicy") == "Always":
      sidecars=add(sidecars,r)
    else:
      peak=(max(peak[0],r[0]+sidecars[0]),max(peak[1],r[1]+sidecars[1]))
  total=add(apps,sidecars)
  total=(max(total[0],peak[0]),max(total[1],peak[1]))
  over=spec.get("overhead") or {}
  return add(total,(quantity(over["cpu"])*1000 if "cpu" in over else Fraction(0),
                    quantity(over["memory"]) if "memory" in over else Fraction(0)))
def pct(used,total):
  if total is None or total <= 0:
    return None
  return int(Fraction(100)*used/total+Fraction(1,2))
def cpu_text(milli):
  return "%dm" % int(milli+Fraction(1,2))
def mem_text(size):
  if size >= 2**30:
    return "%.1fGi" % float(size/2**30)
  return "%dMi" % int(size/2**20+Fraction(1,2))
def cell(used,total,text):
  share=pct(used,total)
  return "%s/%s %s" % (text(used),text(total) if total else "?","%d%%" % share if share is not None else "?%")
if pods is not None:
  per_node={}
  pending=[]
  bare=0
  for p in pods:
    meta=p.get("metadata") or {}
    spec=p.get("spec") or {}
    status=p.get("status") or {}
    phase=status.get("phase","")
    if phase in ("Succeeded","Failed"):
      continue
    node_name=spec.get("nodeName") or ""
    if not node_name:
      for c in status.get("conditions") or []:
        if c.get("type") == "PodScheduled" and c.get("status") == "False" and c.get("reason") == "Unschedulable":
          message=" ".join(str(c.get("message") or "").split())[:100]
          pending.append("pending %s/%s: %s" % (meta.get("namespace",""),meta["name"],message or "Unschedulable"))
      continue
    cpu,mem=pod_request(spec)
    if cpu == 0 and mem == 0:
      bare+=1
    total=per_node.setdefault(node_name,[Fraction(0),Fraction(0),0])
    total[0]+=cpu
    total[1]+=mem
    total[2]+=1
if nodes is not None and pods is not None:
  rows=[("NODE","CPU REQ/ALLOC","MEMORY REQ/ALLOC","PODS","FLAGS")]
  findings=[]
  sums=[Fraction(0),Fraction(0),0,Fraction(0),Fraction(0),0]
  for n in sorted(nodes,key=lambda n: n["metadata"]["name"]):
    name=n["metadata"]["name"]
    alloc=(n.get("status") or {}).get("allocatable") or {}
    a_cpu=quantity(alloc["cpu"])*1000 if "cpu" in alloc else None
    a_mem=quantity(alloc["memory"]) if "memory" in alloc else None
    a_pods=int(quantity(alloc["pods"])) if "pods" in alloc else None
    used=per_node.get(name,[Fraction(0),Fraction(0),0])
    ready=False
    for c in (n.get("status") or {}).get("conditions") or []:
      if c.get("type") == "Ready":
        ready=c.get("status") == "True"
    spec=n.get("spec") or {}
    flags=[]
    if not ready:
      flags.append("NotReady")
    if spec.get("unschedulable") is True:
      flags.append("cordoned")
    flags.extend("%s:%s" % (t.get("key",""),t.get("effect","")) for t in spec.get("taints") or []
                 if t.get("key") != "node.kubernetes.io/unschedulable")
    rows.append((name,cell(used[0],a_cpu,cpu_text),cell(used[1],a_mem,mem_text),
                 "%d/%s %s" % (used[2],a_pods if a_pods else "?","%d%%" % pct(used[2],a_pods) if a_pods else "?%"),
                 ",".join(flags) or "-"))
    hot=[]
    for label,share in (("cpu",pct(used[0],a_cpu)),("memory",pct(used[1],a_mem)),("pods",pct(used[2],a_pods))):
      if share is not None and share >= threshold:
        hot.append("%s %d%%" % (label,share))
    if hot:
      findings.append("node %s: %s requested (threshold %d%%)" % (name,", ".join(hot),threshold))
    if not ready:
      findings.append("node %s: NotReady" % name)
    if ready and spec.get("unschedulable") is not True:
      for i,v in enumerate((used[0],used[1],used[2],a_cpu or 0,a_mem or 0,a_pods or 0)):
        sums[i]+=v
  widths=[max(len(r[i]) for r in rows) for i in range(4)]
  for r in rows:
    out.append("T\t%s  %s  %s  %s  %s" % (r[0].ljust(widths[0]),r[1].ljust(widths[1]),
                                          r[2].ljust(widths[2]),r[3].ljust(widths[3]),r[4]))
  out.extend("F\t"+f for f in findings)
  if sums[3] or sums[4] or sums[5]:
    out.append("I\tcluster   schedulable Ready nodes: cpu %s, memory %s, pods %s" % (
      cell(sums[0],sums[3],cpu_text),cell(sums[1],sums[4],mem_text),
      "%d/%d %s" % (sums[2],sums[5],"%d%%" % pct(sums[2],sums[5]) if sums[5] else "?%")))
  else:
    out.append("I\tcluster   no schedulable Ready node to add up")
if pods is not None:
  out.append("I\trequests  %d scheduled pod(s) declare no cpu or memory request; the totals above count them as free" % bare)
  out.append("S\tPending")
  out.extend("F\t"+p for p in pending)
  if not pending:
    out.append("Q\tno pods pending as Unschedulable")
print("\n".join(out))
' "$THRESHOLD" 2>/dev/null)"; then
  warn "could not parse node or pod quantities (requests, overhead or allocatable)"
  CHECK_ERRORS=$((CHECK_ERRORS + 1))
  report=""
fi

while IFS=$'\t' read -r tag text; do
  [[ -n "$tag" ]] || continue
  case "$tag" in
    T) printf '  %s\n' "$text" ;;
    S) section "$text" ;;
    I) info "$text" ;;
    Q) ok "$text" ;;
    F) warn "$text"; FINDINGS=$((FINDINGS + 1)) ;;
    E) warn "could not parse $text JSON"; CHECK_ERRORS=$((CHECK_ERRORS + 1)) ;;
  esac
done <<<"$report"

printf "\n"
if (( CHECK_ERRORS > 0 )); then
  err "${CHECK_ERRORS} query or JSON parsing check(s) failed; capacity check incomplete"
  exit 1
fi
if (( FINDINGS == 0 )); then
  ok "capacity looks quiet (no node at or above ${THRESHOLD}%, nothing pending)"
  exit 4
fi
info "${FINDINGS} finding(s)"
exit 0
