#!/usr/bin/env bash
# kubectl_drain_preflight.sh
# Read-only "can I safely drain this node?" check: PodDisruptionBudgets that
# allow no disruption, bare pods, nowhere to reschedule, emptyDir data and
# PVC-bound pods. Prints the cordon and drain commands; never runs them.
#
# Usage:
#   ./kubectl_drain_preflight.sh --node NAME [--context CTX]
#
# Exit codes:
#   0 blockers or notes reported
#   1 query or JSON parsing failed (no verdict)
#   2 kubectl or python3 missing / cannot reach cluster
#   3 bad arguments
#   4 nothing to report: no blockers found
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
$(basename "$0") - read-only check of whether a node can be drained

Usage:
  $(basename "$0") --node NAME [--context CTX]

Reports what would stall or hurt a drain before anything is cordoned:
BLOCKER lines for pods covered by a PodDisruptionBudget that allows no
disruption (or by more than one budget), pods with no controller, and no
other Ready, schedulable node to move to, and pods whose nodeSelector,
required nodeAffinity or bound volume (a local PersistentVolume) no other
Ready, schedulable node satisfies; NOTE lines for emptyDir data that
would be lost, pods bound to a PVC, and StatefulSet pods. DaemonSet, static
and finished pods are counted and left out, as kubectl drain leaves them.
Where evicted pods land is not simulated (taints, resources, topology, soft
affinity), so a clean run means no blockers found, not a promise. Then it
prints the kubectl cordon and kubectl drain commands with only the flags
this node needs. It never runs them.

Options:
  --node NAME             Node to check (required)
  --context CTX           kubectl context
  -h, --help              Show this help

Exit codes: 0 blockers or notes reported, 1 query or JSON parsing error
            (no verdict), 2 wrong environment, 3 usage,
            4 nothing to report: no blockers found
EOF
}

NODE=""
CONTEXT=""
KUBECTL=(kubectl)
FINDINGS=0
BLOCKERS=0

while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --node) require_value "$1" "${2:-}"; NODE="$2"; shift ;;
    --node=*) NODE="${1#*=}"; require_value "--node" "$NODE" ;;
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

if [[ -z "$NODE" ]]; then
  err "--node is required"
  usage >&2
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

# The printed commands name the context this run read, so pasting them cannot
# cordon a node of the same name in whichever context is current by then.
next_step() {
  local cmd="$1"
  if [[ -n "$CONTEXT" ]]; then
    cmd="kubectl --context $(printf '%q' "$CONTEXT") ${cmd#kubectl }"
  fi
  info "next      $cmd"
}

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

section "Node $NODE"
fetch "read node $NODE" node "$NODE"
node_json="$FETCHED"
fetch "list pods on $NODE" pods --all-namespaces --field-selector "spec.nodeName=$NODE"
pod_json="$FETCHED"
fetch "list PodDisruptionBudgets" pdb --all-namespaces
pdb_json="$FETCHED"
fetch "list nodes" nodes
nodes_json="$FETCHED"
fetch "list PersistentVolumeClaims" pvc --all-namespaces
pvc_json="$FETCHED"
fetch "list PersistentVolumes" pv
pv_json="$FETCHED"
FETCHED=""

# The six documents travel on one pipe, split by the ASCII record separator,
# which valid JSON cannot contain unescaped.
RS=$'\x1e'
NEED_EMPTYDIR=0
NEED_FORCE=0
if ! report="$(printf '%s%s%s%s%s%s%s%s%s%s%s' "$node_json" "$RS" "$pod_json" "$RS" "$pdb_json" "$RS" "$nodes_json" "$RS" "$pvc_json" "$RS" "$pv_json" | python3 -c '
import json,sys
node_name=sys.argv[1]
parts=sys.stdin.read().split("\x1e")
if len(parts) != 6:
  raise ValueError("expected six documents")
out=[]
def load(raw,what,single=False):
  # An empty part is a query that already failed and was counted.
  if not raw.strip():
    return None
  try:
    doc=json.loads(raw)
    if single:
      if not isinstance(doc,dict) or not (doc.get("metadata") or {}).get("name"):
        raise ValueError("expected one named object")
      return doc
    items=doc["items"]
    if not isinstance(items,list) or any(not isinstance(i,dict) for i in items):
      raise ValueError("expected a Kubernetes items list")
    for i in items:
      if not (i.get("metadata") or {}).get("name"):
        raise ValueError("every item needs a name")
    return items
  except (ValueError,KeyError,TypeError):
    out.append("E\t"+what)
    return None
node=load(parts[0],"node",True)
pods=load(parts[1],"pods")
pdbs=load(parts[2],"PodDisruptionBudgets")
nodes=load(parts[3],"nodes")
pvcs=load(parts[4],"PersistentVolumeClaims")
pvs=load(parts[5],"PersistentVolumes")
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
def expr_ok(e,labels):
  # One node-selector requirement. Anything this does not understand counts
  # as satisfiable, so only a certain mismatch is ever reported.
  key=e.get("key")
  op=e.get("operator")
  values=e.get("values") or []
  if op == "In":
    return key in labels and labels[key] in values
  if op == "NotIn":
    return not (key in labels and labels[key] in values)
  if op == "Exists":
    return key in labels
  if op == "DoesNotExist":
    return key not in labels
  if op in ("Gt","Lt"):
    try:
      want=int(values[0])
    except (IndexError,ValueError,TypeError):
      return True
    try:
      have=int(labels[key])
    except (KeyError,ValueError,TypeError):
      return False
    return have > want if op == "Gt" else have < want
  return True
def terms_ok(terms,n):
  # nodeSelectorTerms are ORed, the requirements inside one term are ANDed.
  if not terms:
    return True
  labels=(n.get("metadata") or {}).get("labels") or {}
  fields={"metadata.name":n["metadata"]["name"]}
  for t in terms:
    good=all(expr_ok(e,labels) for e in t.get("matchExpressions") or [])
    for e in t.get("matchFields") or []:
      if e.get("key") in fields and not expr_ok(e,fields):
        good=False
    if good:
      return True
  return False
def pod_fits(spec,n):
  labels=(n.get("metadata") or {}).get("labels") or {}
  for key,value in (spec.get("nodeSelector") or {}).items():
    if labels.get(key) != value:
      return False
  req=((spec.get("affinity") or {}).get("nodeAffinity") or {}).get("requiredDuringSchedulingIgnoredDuringExecution") or {}
  return terms_ok(req.get("nodeSelectorTerms"),n)
def ready(n):
  for c in (n.get("status") or {}).get("conditions") or []:
    if c.get("type") == "Ready":
      return c.get("status") == "True", c.get("reason") or ""
  return False, "no Ready condition"
if node is not None:
  is_ready,reason=ready(node)
  out.append("I\tready     %s" % ("Ready" if is_ready else "NotReady" + (" (%s)" % reason if reason else "")))
  spec=node.get("spec") or {}
  if spec.get("unschedulable") is True:
    out.append("I\tcordoned  already (spec.unschedulable); cordon again is harmless")
  taints=["%s%s:%s" % (t.get("key",""),"=" + t["value"] if t.get("value") else "",t.get("effect",""))
          for t in spec.get("taints") or []]
  out.append("I\ttaints    %s" % (", ".join(taints) if taints else "none"))
blockers=[]
notes=[]
need=set()
evictable=[]
if pods is not None:
  daemon=mirror=finished=0
  for p in pods:
    meta=p.get("metadata") or {}
    ns=meta.get("namespace","")
    name=meta["name"]
    if (p.get("status") or {}).get("phase") in ("Succeeded","Failed"):
      finished+=1
      continue
    if "kubernetes.io/config.mirror" in (meta.get("annotations") or {}):
      mirror+=1
      continue
    owner=None
    for ref in meta.get("ownerReferences") or []:
      if ref.get("controller") is True:
        owner=ref
    if owner is not None and owner.get("kind") == "DaemonSet":
      daemon+=1
      continue
    evictable.append(p)
    label="pod %s/%s" % (ns,name)
    if owner is None:
      blockers.append("%s has no controller: kubectl drain refuses it without --force, and it will not be recreated" % label)
      need.add("force")
    elif owner.get("kind") == "StatefulSet":
      notes.append("%s belongs to StatefulSet %s: it is replaced in order, under the same name" % (label,owner.get("name","")))
    volumes=(p.get("spec") or {}).get("volumes") or []
    empty=[v.get("name","") for v in volumes if "emptyDir" in v]
    claims=[(v.get("persistentVolumeClaim") or {}).get("claimName","") for v in volumes if "persistentVolumeClaim" in v]
    if empty:
      notes.append("%s uses emptyDir %s: its data is lost; drain needs --delete-emptydir-data" % (label,", ".join(empty)))
      need.add("emptydir")
    if claims:
      notes.append("%s mounts PVC %s: it restarts only where that volume can attach (a zonal disk stays in its zone)" % (label,", ".join(claims)))
  out.append("I\tpods      %d to evict, %d DaemonSet (skipped by --ignore-daemonsets), %d static/mirror (left alone), %d finished (ignored)" % (len(evictable),daemon,mirror,finished))
  if pdbs is not None:
    for p in evictable:
      meta=p.get("metadata") or {}
      labels=meta.get("labels") or {}
      hits=[b for b in pdbs if (b.get("metadata") or {}).get("namespace") == meta.get("namespace")
            and matches((b.get("spec") or {}).get("selector"),labels)]
      label="pod %s/%s" % (meta.get("namespace",""),meta["name"])
      if (p.get("status") or {}).get("phase") == "Pending":
        # The eviction API deletes a Pending pod without asking any budget.
        continue
      unhealthy=not any(c.get("type") == "Ready" and c.get("status") == "True"
                        for c in (p.get("status") or {}).get("conditions") or [])
      if len(hits) > 1:
        blockers.append("%s matches %d PodDisruptionBudgets: the eviction API refuses a pod with more than one" % (label,len(hits)))
      for b in hits:
        allowed=(b.get("status") or {}).get("disruptionsAllowed") or 0
        if isinstance(allowed,bool) or not isinstance(allowed,int):
          raise ValueError("disruptionsAllowed must be an integer")
        if allowed < 1 and unhealthy and (b.get("spec") or {}).get("unhealthyPodEvictionPolicy") == "AlwaysAllow":
          # AlwaysAllow lets the eviction API remove a pod that is not
          # Ready even when the budget allows no disruption.
          continue
        if allowed < 1:
          blockers.append("%s: drain will wait forever: PDB %s/%s allows 0 disruptions" % (label,meta.get("namespace",""),b["metadata"]["name"]))
  if nodes is not None and evictable:
    others=[n for n in nodes if n["metadata"]["name"] != node_name
            and ready(n)[0] and (n.get("spec") or {}).get("unschedulable") is not True]
    if not others:
      blockers.append("no other node is Ready and schedulable: %d evicted pod(s) cannot reschedule anywhere" % len(evictable))
    else:
      # Only the certain cases: a required nodeSelector or nodeAffinity, or
      # a bound volume, that no other Ready schedulable node satisfies.
      claims_by={((c.get("metadata") or {}).get("namespace",""),c["metadata"]["name"]):c for c in pvcs or []}
      pv_by={v["metadata"]["name"]:v for v in pvs or []}
      for p in evictable:
        meta=p.get("metadata") or {}
        spec=p.get("spec") or {}
        label="pod %s/%s" % (meta.get("namespace",""),meta["name"])
        if not any(pod_fits(spec,n) for n in others):
          blockers.append("%s cannot move: its nodeSelector or required nodeAffinity matches no other Ready schedulable node" % label)
        if pvcs is None or pvs is None:
          continue
        for v in spec.get("volumes") or []:
          claim=(v.get("persistentVolumeClaim") or {}).get("claimName")
          bound=((claims_by.get((meta.get("namespace",""),claim)) or {}).get("spec") or {}).get("volumeName")
          pv=pv_by.get(bound)
          if pv is None:
            continue
          terms=((((pv.get("spec") or {}).get("nodeAffinity") or {}).get("required")) or {}).get("nodeSelectorTerms")
          if terms and not any(terms_ok(terms,n) for n in others):
            blockers.append("%s cannot move: PVC %s is bound to PV %s, whose nodeAffinity matches no other Ready schedulable node (a local volume stays on its node)" % (label,claim,bound))
out.append("S\tBlockers")
out.extend("B\t"+b for b in blockers)
if not blockers and node is not None and pods is not None and pdbs is not None and nodes is not None and pvcs is not None and pvs is not None:
  out.append("Q\tno blockers found")
out.append("S\tNotes")
out.extend("O\t"+n for n in notes)
if not notes and pods is not None:
  out.append("Q\tnothing to note")
out.extend("X\t"+n for n in sorted(need))
print("\n".join(out))
' "$NODE" 2>/dev/null)"; then
  warn "could not parse the node, pod and PodDisruptionBudget data"
  CHECK_ERRORS=$((CHECK_ERRORS + 1))
  report=""
fi

while IFS=$'\t' read -r tag text; do
  [[ -n "$tag" ]] || continue
  case "$tag" in
    S) section "$text" ;;
    I) info "$text" ;;
    Q) ok "$text" ;;
    B) warn "BLOCKER   $text"; FINDINGS=$((FINDINGS + 1)); BLOCKERS=$((BLOCKERS + 1)) ;;
    O) warn "NOTE      $text"; FINDINGS=$((FINDINGS + 1)) ;;
    E) warn "could not parse $text JSON"; CHECK_ERRORS=$((CHECK_ERRORS + 1)) ;;
    X)
      if [[ "$text" == "emptydir" ]]; then NEED_EMPTYDIR=1; fi
      if [[ "$text" == "force" ]]; then NEED_FORCE=1; fi
      ;;
  esac
done <<<"$report"

printf "\n"
# Without every answer there is no verdict and no command to paste: a drain
# line built from half the data could leave out the flag that matters.
if (( CHECK_ERRORS > 0 )); then
  err "${CHECK_ERRORS} query or JSON parsing check(s) failed; drain preflight incomplete, no verdict"
  exit 1
fi

drain_cmd="kubectl drain $NODE --ignore-daemonsets"
if (( NEED_EMPTYDIR == 1 )); then
  drain_cmd="$drain_cmd --delete-emptydir-data"
fi
if (( NEED_FORCE == 1 )); then
  drain_cmd="$drain_cmd --force"
fi
drain_cmd="$drain_cmd --timeout=300s"

placement="placement of evicted pods is not simulated: taints, affinity, resources, topology"
if (( FINDINGS == 0 )); then
  ok "no blockers found and nothing to note ($placement)"
elif (( BLOCKERS > 0 )); then
  warn "${BLOCKERS} blocker(s): resolve them before draining"
  info "${FINDINGS} finding(s)"
else
  info "${FINDINGS} finding(s); read the notes before draining ($placement)"
fi
next_step "kubectl cordon $NODE"
next_step "$drain_cmd"
if (( NEED_FORCE == 1 )); then
  warn "--force deletes the pods with no controller above, and nothing recreates them"
fi
if (( FINDINGS == 0 )); then
  exit 4
fi
exit 0
