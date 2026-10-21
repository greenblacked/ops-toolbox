#!/usr/bin/env bash
# kubectl_pod_cleanup.sh
# Remove dead pods: Failed (Evicted and the like) and, on request, Succeeded
# pods older than a grace period. Previews by default; deletes only with
# --yes, and then only the pods it listed, one by one, by name, each re-checked
# (phase) just before its delete, which carries a uid precondition so a pod
# recreated under the same name is refused by the API server (409).
#
# Usage:
#   ./kubectl_pod_cleanup.sh [--namespace NS] [--context CTX] [--all-namespaces]
#                            [--older-than 30m|2h|1d] [--include-succeeded]
#                            [--max N] [--dry-run] [--yes]
#
# Exit codes:
#   0 previewed, or every listed pod deleted (or already gone)
#   1 the listing failed, or at least one delete failed
#   2 kubectl or python3 missing / cannot reach cluster (a preview still
#     answers: it prints the listing command instead)
#   3 bad arguments, or more pods match than --max allows
#   4 no pod matches
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
$(basename "$0") - preview, then delete, dead Failed and Succeeded pods

Usage:
  $(basename "$0") [--namespace NS] [--context CTX] [--all-namespaces]
                  [--older-than 30m|2h|1d] [--include-succeeded]
                  [--max N] [--dry-run] [--yes]

Lists pods in phase Failed (Evicted, OutOfcpu, NodeAffinity, failed Job pods)
whose last start, finish or creation is older than --older-than, and shows the
kubectl delete it would run for each. Nothing is deleted without --yes, and
--dry-run always wins. With --yes it deletes exactly the pods it listed, one
at a time, by name and namespace: never a selector, never --force, never a
zero grace period. Each pod is re-read just before its
delete and skipped if it left its listed phase. The delete itself is a
DeleteOptions request with the listed uid as a precondition
(kubectl delete --raw, body on stdin), so the API server refuses it (409
Conflict) when the pod was recreated in between; that is reported as skipped.
Running, Pending and already-terminating pods are never
candidates. The context is printed before anything is deleted.

Options:
  --namespace NS, -n NS   Only this namespace
  --all-namespaces, -A    Every namespace (default when -n is omitted)
  --context CTX           kubectl context
  --older-than DURATION   Grace period (default: 1d; units m, h, d). A failed
                          pod is post-mortem evidence, so keep it a while
  --include-succeeded     Also remove Succeeded pods past the grace period
  --max N                 Refuse when more than N pods match (default: 200)
  --dry-run               Preview only, even with --yes
  --yes                   Delete the listed pods
  -h, --help              Show this help

Exit codes: 0 previewed or deleted, 1 listing or a delete failed,
            2 wrong environment (a preview still prints the listing command),
            3 usage or more than --max pods match, 4 no pod matches
EOF
}

NAMESPACE=""
CONTEXT=""
ALL_NS=1
KUBECTL=(kubectl)
OLDER_THAN="1d"
INCLUDE_SUCCEEDED=0
MAX=200
DRY_RUN=0
ASSUME_YES=0

while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -n|--namespace) require_value "$1" "${2:-}"; NAMESPACE="$2"; ALL_NS=0; shift ;;
    --namespace=*) NAMESPACE="${1#*=}"; require_value "--namespace" "$NAMESPACE"; ALL_NS=0 ;;
    -A|--all-namespaces) ALL_NS=1; NAMESPACE="" ;;
    --context) require_value "$1" "${2:-}"; CONTEXT="$2"; shift ;;
    --context=*) CONTEXT="${1#*=}"; require_value "--context" "$CONTEXT" ;;
    --older-than) require_value "$1" "${2:-}"; OLDER_THAN="$2"; shift ;;
    --older-than=*) OLDER_THAN="${1#*=}"; require_value "--older-than" "$OLDER_THAN" ;;
    --include-succeeded) INCLUDE_SUCCEEDED=1 ;;
    --max) require_value "$1" "${2:-}"; MAX="$2"; shift ;;
    --max=*) MAX="${1#*=}"; require_value "--max" "$MAX" ;;
    --dry-run) DRY_RUN=1 ;;
    --yes) ASSUME_YES=1 ;;
    *)
      err "unknown option: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

if ! [[ "$OLDER_THAN" =~ ^[1-9][0-9]*[mhd]$ ]]; then
  err "--older-than must be a positive duration ending in m, h or d (for example 30m or 2h)"
  exit 3
fi

if ! [[ "$MAX" =~ ^[1-9][0-9]*$ ]]; then
  err "--max must be a positive whole number (for example 200)"
  exit 3
fi

# --yes alone deletes; anything else previews, and --dry-run wins over --yes.
PREVIEW=1
if (( ASSUME_YES == 1 && DRY_RUN == 0 )); then
  PREVIEW=0
fi

if [[ -n "$CONTEXT" ]]; then
  KUBECTL+=(--context "$CONTEXT")
fi

ns_args=()
scope="all namespaces"
if (( ALL_NS == 1 )); then
  ns_args+=(--all-namespaces)
elif [[ -n "$NAMESPACE" ]]; then
  ns_args+=(--namespace "$NAMESPACE")
  scope="namespace $NAMESPACE"
fi
list_cmd=("${KUBECTL[@]}" get pods "${ns_args[@]}" -o json)

# A preview answers on a machine without the tools or the cluster, the way
# debug_pod.sh and build.sh do: it prints the one read it would have made.
# Deleting anything still needs all of them.
preview_offline() {
  warn "$1; printing the listing command instead"
  printf "dry-run: would run:"
  printf " %q" "${list_cmd[@]}"
  printf "\n"
  printf "dry-run complete; no changes written\n"
  exit 0
}

if ! command -v kubectl >/dev/null 2>&1; then
  if (( PREVIEW == 1 )); then
    preview_offline "kubectl is not installed"
  fi
  err "kubectl is not installed or not on PATH"
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  if (( PREVIEW == 1 )); then
    preview_offline "python3 is not installed"
  fi
  err "python3 is not installed or not on PATH"
  exit 2
fi

if ! "${KUBECTL[@]}" cluster-info >/dev/null 2>&1; then
  if (( PREVIEW == 1 )); then
    preview_offline "cannot reach the cluster"
  fi
  err "cannot reach the cluster (check kubeconfig / context)"
  exit 2
fi

section() { printf "\n%s== %s ==%s\n" "$C_BOLD" "$*" "$C_RESET"; }

effective_context="$CONTEXT"
if [[ -z "$effective_context" ]]; then
  effective_context="$(kubectl config current-context 2>/dev/null || true)"
fi
phases="Failed"
if (( INCLUDE_SUCCEEDED == 1 )); then
  phases="Failed and Succeeded"
fi
info "context   ${effective_context:-(none)}"
info "scope     $scope"
info "select    $phases pods last active more than $OLDER_THAN ago"
if (( PREVIEW == 1 )); then
  info "mode      preview: nothing is deleted"
else
  warn "mode      delete (--yes)"
fi

pod_json=""
pod_rc=0
pod_json="$("${list_cmd[@]}" 2>/dev/null)" || pod_rc=$?
if (( pod_rc != 0 )) || [[ -z "$pod_json" ]]; then
  err "could not list pods"
  exit 1
fi
if ! plan="$(printf '%s' "$pod_json" | python3 -c '
import datetime,json,sys
raw=sys.argv[1]
seconds=int(raw[:-1]) * {"m": 60, "h": 3600, "d": 86400}[raw[-1]]
include_succeeded=sys.argv[2] == "1"
now=datetime.datetime.now(datetime.timezone.utc)
cutoff=now-datetime.timedelta(seconds=seconds)
doc=json.load(sys.stdin)
items=doc["items"]
if not isinstance(items,list) or any(not isinstance(p,dict) for p in items):
  raise ValueError("expected a Kubernetes items list")
def when(text):
  try:
    stamp=datetime.datetime.fromisoformat(str(text).replace("Z","+00:00"))
  except (ValueError,TypeError):
    return None
  return stamp if stamp.tzinfo is not None else None
def age(delta):
  minutes=int(delta.total_seconds() // 60)
  if minutes >= 2880:
    return "%dd" % (minutes // 1440)
  if minutes >= 120:
    return "%dh" % (minutes // 60)
  return "%dm" % minutes
rows=[]
for p in items:
  meta=p.get("metadata") or {}
  status=p.get("status") or {}
  ns=meta.get("namespace","")
  name=meta.get("name","")
  if not ns or not name:
    raise ValueError("pod metadata must identify namespace and name")
  phase=status.get("phase","")
  # Only terminal pods: Running, Pending and Unknown are never candidates,
  # and a pod already being deleted is left to the controller.
  if phase != "Failed" and not (phase == "Succeeded" and include_succeeded):
    continue
  if meta.get("deletionTimestamp"):
    continue
  # The newest of start, last container finish and creation: a pod is only
  # as old as the last thing that happened to it.
  stamps=[when(status.get("startTime")),when(meta.get("creationTimestamp"))]
  for key in ("containerStatuses","initContainerStatuses"):
    for cs in status.get(key) or []:
      terminated=((cs or {}).get("state") or {}).get("terminated") or {}
      stamps.append(when(terminated.get("finishedAt")))
  stamps=[s for s in stamps if s is not None]
  if not stamps:
    continue
  latest=max(stamps)
  if latest > cutoff:
    continue
  reason=status.get("reason") or ""
  uid=meta.get("uid") or "-"
  rows.append((ns,name,"%s%s" % (phase," (%s)" % reason if reason else ""),age(now-latest),uid,phase))
rows.sort()
print("\n".join("%s\t%s\t%s\t%s\t%s\t%s" % row for row in rows))
' "$OLDER_THAN" "$INCLUDE_SUCCEEDED" 2>/dev/null)"; then
  err "could not parse pods JSON"
  exit 1
fi
pod_json=""

count=0
section "Candidates"
while IFS=$'\t' read -r ns name reason age uid phase; do
  [[ -n "$name" ]] || continue
  count=$((count + 1))
  info "pod ${ns}/${name}: ${reason}, last active ${age} ago"
done <<<"$plan"

if (( count == 0 )); then
  ok "no $phases pods older than $OLDER_THAN"
  exit 4
fi

# The cap is checked in a preview too, so the preview says what --yes would do.
if (( count > MAX )); then
  if (( PREVIEW == 1 )); then
    warn "$count pods match; raise --max or narrow with --namespace/--older-than"
  else
    err "$count pods match; raise --max or narrow with --namespace/--older-than"
  fi
  exit 3
fi

if (( PREVIEW == 1 )); then
  section "Preview"
  while IFS=$'\t' read -r ns name reason age uid phase; do
    [[ -n "$name" ]] || continue
    printf "dry-run: would run:"
    if [[ "$uid" != "-" ]]; then
      printf " %q" "${KUBECTL[@]}" delete --raw "/api/v1/namespaces/${ns}/pods/${name}" -f -
      printf " # DeleteOptions precondition uid=%s" "$uid"
    else
      printf " %q" "${KUBECTL[@]}" delete pod "$name" --namespace "$ns" --wait=false
    fi
    printf "\n"
  done <<<"$plan"
  printf "dry-run complete; no changes written\n"
  info "re-run with --yes to delete ${count} pod(s)"
  exit 0
fi

section "Deleting"
deleted=0
gone=0
skipped=0
failed=0
while IFS=$'\t' read -r ns name reason age uid phase; do
  [[ -n "$name" ]] || continue
  out=""
  # Re-read the pod right before deleting it: a pod recreated under the same
  # name since the listing (new uid, or no longer terminal) is left alone.
  if cur="$("${KUBECTL[@]}" get pod "$name" --namespace "$ns" \
      -o 'jsonpath={.metadata.uid},{.status.phase},{.metadata.deletionTimestamp}' 2>&1)"; then
    cur_uid="${cur%%,*}"
    cur_rest="${cur#*,}"
    cur_phase="${cur_rest%%,*}"
    cur_deleting="${cur_rest#*,}"
    if [[ "$cur_phase" != "$phase" || -n "$cur_deleting" ]] \
      || [[ "$uid" != "-" && "$cur_uid" != "$uid" ]]; then
      skipped=$((skipped + 1))
      warn "skipped ${ns}/${name}: it changed since the listing (now ${cur_phase:-unknown})"
      continue
    fi
  elif [[ "$cur" == *NotFound* || "$cur" == *"not found"* ]]; then
    gone=$((gone + 1))
    ok "already gone: ${ns}/${name}"
    continue
  else
    failed=$((failed + 1))
    warn "could not re-check ${ns}/${name}: ${cur%%$'\n'*}"
    continue
  fi
  # The re-read above is only a fast path: kubectl delete by name checks no
  # uid, so a pod recreated between that read and this call would be deleted.
  # The uid precondition makes the API server refuse it (409 Conflict).
  if [[ "$uid" != "-" ]]; then
    body="{\"kind\":\"DeleteOptions\",\"apiVersion\":\"v1\",\"preconditions\":{\"uid\":\"${uid}\"}}"
    out="$("${KUBECTL[@]}" delete --raw "/api/v1/namespaces/${ns}/pods/${name}" -f - 2>&1 >/dev/null <<<"$body")"
    drc=$?
  else
    out="$("${KUBECTL[@]}" delete pod "$name" --namespace "$ns" --wait=false 2>&1 >/dev/null)"
    drc=$?
  fi
  if (( drc == 0 )); then
    deleted=$((deleted + 1))
    ok "deleted ${ns}/${name}"
  elif [[ "$out" == *Conflict* || "$out" == *"Precondition failed"* ]]; then
    skipped=$((skipped + 1))
    warn "skipped ${ns}/${name}: recreated since the listing (uid precondition failed)"
  elif [[ "$out" == *NotFound* || "$out" == *"not found"* ]]; then
    gone=$((gone + 1))
    ok "already gone: ${ns}/${name}"
  else
    failed=$((failed + 1))
    warn "could not delete ${ns}/${name}: ${out%%$'\n'*}"
  fi
done <<<"$plan"

printf "\n"
info "deleted ${deleted}, already gone ${gone}, skipped ${skipped}, failed ${failed}"
if (( failed > 0 )); then
  err "${failed} delete(s) failed"
  exit 1
fi
exit 0
