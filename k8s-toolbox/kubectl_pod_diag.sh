#!/usr/bin/env bash
# kubectl_pod_diag.sh
# Read-only cluster triage: unhealthy pods and containers, recent OOM kills
# and restart loops, Warning events, failing container logs, unbound PVCs, and
# node pressure conditions.
#
# Usage:
#   ./kubectl_pod_diag.sh [--namespace NS] [--context CTX] [--all-namespaces]
#                         [--since 30m|2h|1d] [--restarts N]
#
# Exit codes:
#   0 findings reported
#   1 query or JSON parsing failed
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
                  [--since 30m|2h|1d] [--restarts N]

Options:
  --namespace NS, -n NS   Limit pod/event/PVC checks to one namespace
  --all-namespaces, -A    Scan every namespace (default when -n is omitted)
  --context CTX           kubectl context
  --since DURATION        Warning-event and OOM-kill lookback
                          (default: 1h; units m, h, d)
  --restarts N            Report a running, ready container restarted at
                          least N times (default: 5)
  -h, --help              Show this help

Exit codes: 0 reported findings, 1 query or JSON parsing error,
            2 wrong environment, 3 usage, 4 nothing to report
EOF
}

NAMESPACE=""
CONTEXT=""
ALL_NS=1
KUBECTL=(kubectl)
FINDINGS=0
SINCE="1h"
RESTARTS=5

while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -n|--namespace) require_value "$1" "${2:-}"; NAMESPACE="$2"; ALL_NS=0; shift ;;
    --namespace=*) NAMESPACE="${1#*=}"; require_value "--namespace" "$NAMESPACE"; ALL_NS=0 ;;
    -A|--all-namespaces) ALL_NS=1; NAMESPACE="" ;;
    --context) require_value "$1" "${2:-}"; CONTEXT="$2"; shift ;;
    --context=*) CONTEXT="${1#*=}"; require_value "--context" "$CONTEXT" ;;
    --since) require_value "$1" "${2:-}"; SINCE="$2"; shift ;;
    --since=*) SINCE="${1#*=}"; require_value "--since" "$SINCE" ;;
    --restarts) require_value "$1" "${2:-}"; RESTARTS="$2"; shift ;;
    --restarts=*) RESTARTS="${1#*=}"; require_value "--restarts" "$RESTARTS" ;;
    *)
      err "unknown option: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

if ! [[ "$SINCE" =~ ^[1-9][0-9]*[mhd]$ ]]; then
  err "--since must be a positive duration ending in m, h or d (for example 30m or 2h)"
  exit 3
fi

# Zero would report every container that ever started, so it is refused.
if ! [[ "$RESTARTS" =~ ^[1-9][0-9]*$ ]]; then
  err "--restarts must be a positive whole number (for example 5)"
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

CHECK_ERRORS=0

section "Unhealthy pods"
pod_json=""
pod_rc=0
pod_parsed=0
pod_json="$("${KUBECTL[@]}" get pods "${ns_args[@]}" -o json 2>/dev/null)" || pod_rc=$?
if (( pod_rc != 0 )) || [[ -z "$pod_json" ]]; then
  warn "could not list pods"
  CHECK_ERRORS=$((CHECK_ERRORS + 1))
else
  if ! bad_pods="$(printf '%s' "$pod_json" | python3 -c '
import json,sys
doc=json.load(sys.stdin)
items=doc["items"]
if not isinstance(items,list) or any(not isinstance(p,dict) for p in items):
  raise ValueError("expected a Kubernetes items list")
rows=[]
for p in items:
  status=p.get("status") or {}
  phase=status.get("phase","")
  if phase == "Succeeded":
    continue
  ns=p.get("metadata",{}).get("namespace","")
  name=p.get("metadata",{}).get("name","")
  if not ns or not name:
    raise ValueError("pod metadata must identify namespace and name")
  sidecars={c["name"] for c in (p.get("spec") or {}).get("initContainers") or []
            if c.get("restartPolicy") == "Always"}
  pod_rows=[]
  for kind,key in (("container","containerStatuses"),("init container","initContainerStatuses")):
    for cs in status.get(key) or []:
      container=cs["name"]
      state=cs.get("state") or {}
      waiting=state.get("waiting") or {}
      terminated=state.get("terminated")
      reason=""
      logs="-"
      if waiting:
        reason=waiting.get("reason") or "Waiting"
        if reason == "CrashLoopBackOff":
          logs="previous"
      elif terminated is not None:
        if terminated.get("exitCode",0) != 0:
          reason=terminated.get("reason") or "Failed"
          logs="current"
        elif phase == "Running" and (kind == "container" or container in sidecars):
          reason=terminated.get("reason") or "Terminated"
      elif cs.get("ready") is False and (kind == "container" or container in sidecars):
        reason="NotReady"
      if reason:
        label="sidecar" if container in sidecars and kind == "init container" else kind
        pod_rows.append("%s\t%s\t%s %s: %s\t%s\t%s" %
                        (ns,name,label,container,reason,container,logs))
  if pod_rows:
    rows.extend(pod_rows)
  elif phase != "Running":
    rows.append("%s\t%s\t%s\t-\t-" % (ns,name,phase or "Unknown"))
print("\n".join(rows))
' 2>/dev/null)"; then
    warn "could not parse pods JSON"
    CHECK_ERRORS=$((CHECK_ERRORS + 1))
  elif [[ -z "$bad_pods" ]]; then
    pod_parsed=1
    ok "no unhealthy pods"
  else
    pod_parsed=1
    while IFS=$'\t' read -r ns name reason container logs; do
      [[ -n "$ns" ]] || continue
      warn "pod ${ns}/${name}: ${reason}"
      FINDINGS=$((FINDINGS + 1))
      if [[ "$logs" != "-" ]]; then
        log_args=()
        [[ "$logs" == "previous" ]] && log_args+=(--previous)
        info "${logs} logs for ${ns}/${name} (container ${container}):"
        "${KUBECTL[@]}" logs -n "$ns" "$name" -c "$container" ${log_args[@]+"${log_args[@]}"} --tail=40 2>/dev/null \
          | sed 's/^/    /' || warn "  (no ${logs} logs for ${container})"
      fi
    done <<<"$bad_pods"
  fi
fi

section "Restarts and OOM kills (last $SINCE, threshold $RESTARTS)"
# A container that was OOMKilled minutes ago, or keeps restarting, can be
# Running and Ready by the time anyone looks. This reuses the pod listing
# above: no extra API call, and a failed listing is counted once, not twice.
if (( pod_parsed == 0 )); then
  info "skipped; the pod listing above could not be read"
else
  if ! restarted="$(printf '%s' "$pod_json" | python3 -c '
import json,sys,datetime
doc=json.load(sys.stdin)
now=datetime.datetime.now(datetime.timezone.utc)
raw=sys.argv[1]
seconds=int(raw[:-1]) * {"m": 60, "h": 3600, "d": 86400}[raw[-1]]
cutoff=now-datetime.timedelta(seconds=seconds)
threshold=int(sys.argv[2])
items=doc["items"]
if not isinstance(items,list) or any(not isinstance(p,dict) for p in items):
  raise ValueError("expected a Kubernetes items list")
rows=[]
for p in items:
  status=p.get("status") or {}
  if status.get("phase") == "Succeeded":
    continue
  ns=p.get("metadata",{}).get("namespace","")
  name=p.get("metadata",{}).get("name","")
  statuses=status.get("containerStatuses") or []
  if not isinstance(statuses,list) or any(not isinstance(cs,dict) for cs in statuses):
    raise ValueError("containerStatuses must be a list of objects")
  limits={}
  for c in (p.get("spec") or {}).get("containers") or []:
    if isinstance(c,dict) and c.get("name"):
      limits[c["name"]]=((c.get("resources") or {}).get("limits") or {}).get("memory") or "-"
  # Native sidecars (initContainers with restartPolicy Always) keep running
  # and restart like regular containers; plain init containers do not count.
  sidecars=set()
  for c in (p.get("spec") or {}).get("initContainers") or []:
    if isinstance(c,dict) and c.get("name") and c.get("restartPolicy") == "Always":
      sidecars.add(c["name"])
      limits[c["name"]]=((c.get("resources") or {}).get("limits") or {}).get("memory") or "-"
  init_statuses=status.get("initContainerStatuses") or []
  if not isinstance(init_statuses,list) or any(not isinstance(cs,dict) for cs in init_statuses):
    raise ValueError("initContainerStatuses must be a list of objects")
  statuses=statuses+[cs for cs in init_statuses if cs.get("name") in sidecars]
  for cs in statuses:
    # Only containers that look healthy right now: anything waiting, terminated
    # or unready is already reported by the unhealthy-pods section.
    if "running" not in (cs.get("state") or {}) or cs.get("ready") is not True:
      continue
    container=cs.get("name") or ""
    restarts=cs.get("restartCount",0)
    if isinstance(restarts,bool) or not isinstance(restarts,int):
      raise ValueError("restartCount must be an integer")
    last=(cs.get("lastState") or {}).get("terminated") or {}
    age="-"
    if last.get("reason") == "OOMKilled":
      try:
        finished=datetime.datetime.fromisoformat(str(last.get("finishedAt")).replace("Z","+00:00"))
        if finished.tzinfo is not None and finished >= cutoff:
          age=str(int((now-finished).total_seconds() // 60))
      except (ValueError,TypeError):
        pass
    if age == "-" and restarts < threshold:
      continue
    rows.append("%s\t%s\t%s\t%d\t%s\t%s\t%s" % (ns,name,container,restarts,
                "OOMKilled" if age != "-" else "-",age,limits.get(container,"-")))
print("\n".join(rows))
' "$SINCE" "$RESTARTS" 2>/dev/null)"; then
    warn "could not parse restart data"
    CHECK_ERRORS=$((CHECK_ERRORS + 1))
  elif [[ -z "$restarted" ]]; then
    ok "no recent OOM kills or restart loops"
  else
    while IFS=$'\t' read -r ns name container count reason age limit; do
      [[ -n "$ns" ]] || continue
      if [[ "$limit" == "-" ]]; then
        limit="no memory limit"
      else
        limit="memory limit $limit"
      fi
      if [[ "$reason" == "OOMKilled" ]]; then
        warn "pod ${ns}/${name}: container ${container} restarted ${count}x, last OOMKilled ${age}m ago (${limit})"
      else
        warn "pod ${ns}/${name}: container ${container} restarted ${count}x (>= ${RESTARTS})"
      fi
      info "next      kubectl${CONTEXT:+ --context $CONTEXT} logs -n ${ns} ${name} -c ${container} --previous"
      FINDINGS=$((FINDINGS + 1))
    done <<<"$restarted"
  fi
fi

section "Warning events (last $SINCE)"
event_json=""
event_rc=0
event_json="$("${KUBECTL[@]}" get events "${ns_args[@]}" --field-selector type=Warning -o json 2>/dev/null)" || event_rc=$?
if (( event_rc != 0 )) || [[ -z "$event_json" ]]; then
  warn "could not list events"
  CHECK_ERRORS=$((CHECK_ERRORS + 1))
else
  if ! warns="$(printf '%s' "$event_json" | python3 -c '
import json,sys,datetime
doc=json.load(sys.stdin)
now=datetime.datetime.now(datetime.timezone.utc)
raw=sys.argv[1]
amount=int(raw[:-1])
unit=raw[-1]
seconds=amount * {"m": 60, "h": 3600, "d": 86400}[unit]
cutoff=now-datetime.timedelta(seconds=seconds)
rows=[]
items=doc["items"]
if not isinstance(items,list) or any(not isinstance(e,dict) for e in items):
  raise ValueError("expected a Kubernetes items list")
for e in items:
  # A series records the latest repetition; eventTime records the first one.
  timestamps=((e.get("series") or {}).get("lastObservedTime"),e.get("lastTimestamp"),
              e.get("deprecatedLastTimestamp"),e.get("eventTime"),
              (e.get("metadata") or {}).get("creationTimestamp"))
  when=None
  for ts in timestamps:
    if not ts:
      continue
    try:
      candidate=datetime.datetime.fromisoformat(ts.replace("Z","+00:00"))
      if candidate.tzinfo is None:
        continue
      when=candidate
      break
    except (ValueError,TypeError,AttributeError):
      continue
  if when is None:
    raise ValueError("Warning event has no usable observation timestamp")
  if when < cutoff:
    continue
  ns=e.get("metadata",{}).get("namespace","")
  name=(e.get("involvedObject") or {}).get("name","")
  reason=e.get("reason") or "Warning"
  msg=(e.get("message") or "").replace("\n"," ")
  rows.append("%s\t%s\t%s\t%s" % (ns, name, reason, msg[:120]))
print("\n".join(rows[:40]))
' "$SINCE" 2>/dev/null)"; then
    warn "could not parse events JSON or Warning observation timestamps"
    CHECK_ERRORS=$((CHECK_ERRORS + 1))
  elif [[ -z "$warns" ]]; then
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
pvc_json=""
pvc_rc=0
pvc_json="$("${KUBECTL[@]}" get pvc "${ns_args[@]}" -o json 2>/dev/null)" || pvc_rc=$?
if (( pvc_rc != 0 )) || [[ -z "$pvc_json" ]]; then
  warn "could not list PVCs"
  CHECK_ERRORS=$((CHECK_ERRORS + 1))
else
  if ! unbound="$(printf '%s' "$pvc_json" | python3 -c '
import json,sys
doc=json.load(sys.stdin)
rows=[]
items=doc["items"]
if not isinstance(items,list) or any(not isinstance(p,dict) for p in items):
  raise ValueError("expected a Kubernetes items list")
for p in items:
  phase=(p.get("status") or {}).get("phase","")
  if phase == "Bound":
    continue
  ns=p.get("metadata",{}).get("namespace","")
  name=p.get("metadata",{}).get("name","")
  if not ns or not name:
    raise ValueError("PVC metadata must identify namespace and name")
  rows.append("%s\t%s\t%s" % (ns, name, phase or "?"))
print("\n".join(rows))
' 2>/dev/null)"; then
    warn "could not parse PVCs JSON"
    CHECK_ERRORS=$((CHECK_ERRORS + 1))
  elif [[ -z "$unbound" ]]; then
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
node_json=""
node_rc=0
node_json="$("${KUBECTL[@]}" get nodes -o json 2>/dev/null)" || node_rc=$?
if (( node_rc != 0 )) || [[ -z "$node_json" ]]; then
  warn "could not list nodes"
  CHECK_ERRORS=$((CHECK_ERRORS + 1))
else
  if ! pressure="$(printf '%s' "$node_json" | python3 -c '
import json,sys
doc=json.load(sys.stdin)
rows=[]
items=doc["items"]
if not isinstance(items,list) or any(not isinstance(n,dict) for n in items):
  raise ValueError("expected a Kubernetes items list")
for n in items:
  name=n.get("metadata",{}).get("name","")
  if not name:
    raise ValueError("node metadata must identify name")
  for c in (n.get("status") or {}).get("conditions") or []:
    ctype=c.get("type","")
    status=c.get("status","")
    if ctype in ("MemoryPressure","DiskPressure","PIDPressure") and status == "True":
      rows.append("%s\t%s\t%s" % (name, ctype, c.get("message","")[:100]))
    if ctype == "Ready" and status != "True":
      rows.append("%s\tReady=%s\t%s" % (name, status, c.get("reason","")))
print("\n".join(rows))
' 2>/dev/null)"; then
    warn "could not parse nodes JSON"
    CHECK_ERRORS=$((CHECK_ERRORS + 1))
  elif [[ -z "$pressure" ]]; then
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
if (( CHECK_ERRORS > 0 )); then
  err "${CHECK_ERRORS} query or JSON parsing check(s) failed; health check incomplete"
  exit 1
fi
if (( FINDINGS == 0 )); then
  ok "cluster looks quiet"
  exit 4
fi
info "${FINDINGS} finding(s)"
exit 0
