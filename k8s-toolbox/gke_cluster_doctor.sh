#!/usr/bin/env bash
# gke_cluster_doctor.sh
# Read-only GKE cluster report: release channel, control-plane vs node-pool
# skew, Workload Identity, private nodes / private endpoint. Prints the
# gcloud command that would fix each finding. Never mutates the cluster.
#
# Usage:
#   ./gke_cluster_doctor.sh --project P --cluster C --location L
#   ./gke_cluster_doctor.sh --list-checks
#   ./gke_cluster_doctor.sh --only channel,skew
#
# Exit codes:
#   0 findings reported or cluster looks healthy
#   1 gcloud failed after connecting
#   2 wrong environment (no gcloud, cluster not resolved)
#   3 bad arguments
#   4 --only selected nothing
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
  "channel|release channel"
  "skew|control-plane vs node-pool versions"
  "identity|Workload Identity pool"
  "network|private nodes / private endpoint"
)

check_ids() {
  local row
  for row in "${CHECKS[@]}"; do
    printf '%s\n' "${row%%|*}"
  done
}

usage() {
  cat <<EOF
$(basename "$0") - read-only GKE cluster doctor

Usage:
  $(basename "$0") [--project P] [--cluster C] [--location L]
                  [--context CTX] [--only CHECK[,CHECK...]] [--list-checks]

Resolves the cluster from flags, or from a kubectl context named
gke_PROJECT_LOCATION_CLUSTER.

Options:
  --project P         GCP project
  --cluster C         GKE cluster name
  --location L        region or zone
  --context CTX       kubectl context (default: current-context)
  --only LIST         Only the named checks (see --list-checks)
  --list-checks       Print stable check ids and exit
  -h, --help          Show this help

Exit codes:
  0  findings reported or the cluster looks healthy
  1  gcloud failed after connecting
  2  wrong environment (no gcloud, cluster not resolved)
  3  usage
  4  --only selected nothing
EOF
}

PROJECT=""
CLUSTER=""
LOCATION=""
CONTEXT=""
ONLY=""
LIST_CHECKS=0
FINDINGS=0

while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --list-checks) LIST_CHECKS=1 ;;
    --project) require_value "$1" "${2:-}"; PROJECT="$2"; shift ;;
    --project=*) PROJECT="${1#*=}"; require_value "--project" "$PROJECT" ;;
    --cluster) require_value "$1" "${2:-}"; CLUSTER="$2"; shift ;;
    --cluster=*) CLUSTER="${1#*=}"; require_value "--cluster" "$CLUSTER" ;;
    --location) require_value "$1" "${2:-}"; LOCATION="$2"; shift ;;
    --location=*) LOCATION="${1#*=}"; require_value "--location" "$LOCATION" ;;
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
    err "--only selected nothing"
    exit 4
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

if ! command -v gcloud >/dev/null 2>&1; then
  err "gcloud is not installed or not on PATH"
  exit 2
fi

if [[ -z "$PROJECT" || -z "$CLUSTER" || -z "$LOCATION" ]]; then
  if command -v kubectl >/dev/null 2>&1; then
    if [[ -z "$CONTEXT" ]]; then
      CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
    fi
    if [[ "$CONTEXT" == gke_* ]]; then
      rest="${CONTEXT#gke_}"
      PROJECT="${rest%%_*}"
      rest="${rest#"${PROJECT}"_}"
      LOCATION="${rest%%_*}"
      CLUSTER="${rest#"${LOCATION}"_}"
      info "using kubectl context $CONTEXT"
    fi
  fi
fi

if [[ -z "$PROJECT" || -z "$CLUSTER" || -z "$LOCATION" ]]; then
  err "could not resolve project/cluster/location (pass --project --cluster --location, or use a gke_PROJECT_LOCATION_CLUSTER kubectl context)"
  exit 2
fi

loc_flag=(--region "$LOCATION")
case "$LOCATION" in
  *-*-*) loc_flag=(--zone "$LOCATION") ;;
esac

describe() {
  gcloud --project "$PROJECT" container clusters describe "$CLUSTER" \
    "${loc_flag[@]}" --format="$1"
}

printf "%s=== gke_cluster_doctor: %s/%s/%s ===%s\n" \
  "$C_BOLD" "$PROJECT" "$LOCATION" "$CLUSTER" "$C_RESET"

if ! master="$(describe 'value(currentMasterVersion)')"; then
  err "gcloud container clusters describe failed"
  exit 1
fi
ok "cluster   reachable, control plane $master"

if want channel; then
  channel="$(describe 'value(releaseChannel.channel)')"
  if [[ -z "$channel" || "$channel" == "UNSPECIFIED" ]]; then
    FINDINGS=1
    warn "channel   no release channel set"
    info "fix       gcloud container clusters update $CLUSTER ${loc_flag[*]} --release-channel regular"
  else
    ok "channel   $channel"
  fi
fi

if want skew; then
  pools="$(describe 'value(nodePools.name,nodePools.version)' | tr ';' '\n')"
  if [[ -z "$pools" ]]; then
    info "skew      no node pools reported"
  else
    while IFS=$'\t' read -r pname pver; do
      [[ -n "$pname" ]] || continue
      if [[ -n "$pver" && -n "$master" && "$pver" != "$master" ]]; then
        FINDINGS=1
        warn "skew      node pool $pname is $pver (control plane $master)"
        info "fix       gcloud container clusters upgrade $CLUSTER ${loc_flag[*]} --node-pool $pname --cluster-version $master"
      else
        ok "skew      node pool $pname is ${pver:-unknown}"
      fi
    done <<< "$pools"
  fi
fi

if want identity; then
  pool="$(describe 'value(workloadIdentityConfig.workloadPool)')"
  if [[ -z "$pool" ]]; then
    FINDINGS=1
    warn "identity  Workload Identity is not set"
    info "fix       gcloud container clusters update $CLUSTER ${loc_flag[*]} --workload-pool=${PROJECT}.svc.id.goog"
  else
    ok "identity  $pool"
  fi
fi

if want network; then
  nodes="$(describe 'value(privateClusterConfig.enablePrivateNodes)')"
  endpoint="$(describe 'value(privateClusterConfig.enablePrivateEndpoint)')"
  ok "network   privateNodes=${nodes:-false} privateEndpoint=${endpoint:-false}"
fi

if (( FINDINGS == 0 )); then
  info "next      no mutating command; re-run after a cluster change"
  exit 0
fi
exit 0
