#!/usr/bin/env bash
# gke_cluster_doctor.sh
# Read-only GKE cluster report: release channel, control-plane vs node-pool
# skew, Workload Identity, private nodes / private endpoint, node auto-repair
# and auto-upgrade, maintenance window, master authorized networks, logging
# and monitoring, shielded nodes, and network policy enforcement. Prints the
# gcloud command that would fix each finding. Never mutates the cluster.
# The last six read one JSON describe through python3; without python3 they
# are skipped with a warning unless --only names them.
#
# Usage:
#   ./gke_cluster_doctor.sh --project P --cluster C --location L
#   ./gke_cluster_doctor.sh --list-checks
#   ./gke_cluster_doctor.sh --only channel,skew
#
# Exit codes:
#   0 findings reported or cluster looks healthy
#   1 gcloud failed after connecting
#   2 wrong environment (no gcloud, cluster not resolved, or no python3
#     for a check --only named)
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
  "nodepool-mgmt|node auto-repair / auto-upgrade"
  "maintenance|maintenance window"
  "authnets|master authorized networks"
  "observability|logging and monitoring"
  "shielded|shielded nodes"
  "dataplane|network policy / Dataplane V2"
)

# These read one JSON describe and need python3 to reduce it.
JSON_CHECKS=" nodepool-mgmt maintenance authnets observability shielded dataplane "

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

Checks: channel, skew, identity, network, nodepool-mgmt, maintenance,
authnets, observability, shielded, dataplane. The last six read one JSON
describe through python3; without python3 they are skipped with a warning,
unless --only names one of them (then exit 2).

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
  2  wrong environment (no gcloud, cluster not resolved, or no python3
     for a check --only named)
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
    id="${raw//[[:space:]]/}"
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

# The four original checks need gcloud alone and keep working without
# python3; the JSON checks are dropped with a warning, unless --only asked
# for one by name, which would otherwise look like a pass.
json_selected=()
for s in "${SELECTED[@]}"; do
  case "$JSON_CHECKS" in
    *" $s "*) json_selected+=("$s") ;;
  esac
done
if (( ${#json_selected[@]} > 0 )) && ! command -v python3 >/dev/null 2>&1; then
  if [[ -n "$ONLY" ]]; then
    err "python3 is not installed or not on PATH (needed by: ${json_selected[*]})"
    exit 2
  fi
  warn "python3 not found; skipping ${json_selected[*]}"
  json_selected=()
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
  # value() prints one tab-separated column per key and joins a repeated field
  # with ';', so two pools arrive as "a;b<TAB>1.30;1.29". Splitting the whole
  # line on ';' paired a pool with its neighbour's version; pair by position.
  pools="$(describe 'value(nodePools.name,nodePools.version)')"
  pool_names=()
  pool_versions=()
  IFS=$'\t' read -r names_col versions_col <<< "$pools"
  IFS=';' read -r -a pool_names <<< "$names_col"
  IFS=';' read -r -a pool_versions <<< "$versions_col"
  if (( ${#pool_names[@]} == 0 )); then
    info "skew      no node pools reported"
  else
    for i in "${!pool_names[@]}"; do
      pname="${pool_names[$i]}"
      pver="${pool_versions[$i]:-}"
      [[ -n "$pname" ]] || continue
      if [[ -n "$pver" && -n "$master" && "$pver" != "$master" ]]; then
        FINDINGS=1
        warn "skew      node pool $pname is $pver (control plane $master)"
        info "fix       gcloud container clusters upgrade $CLUSTER ${loc_flag[*]} --node-pool $pname --cluster-version $master"
      else
        ok "skew      node pool $pname is ${pver:-unknown}"
      fi
    done
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

if (( ${#json_selected[@]} > 0 )); then
  if ! cluster_json="$(describe json)"; then
    err "gcloud container clusters describe --format=json failed"
    exit 1
  fi
  json_csv="$(IFS=','; printf '%s' "${json_selected[*]}")"
  # Reduced to booleans, names and counts: no other field of the description
  # reaches the output.
  if ! report="$(printf '%s' "$cluster_json" | python3 -c '
import json,sys
selected=sys.argv[1].split(",")
cluster=sys.argv[2]
loc=sys.argv[3]
doc=json.load(sys.stdin)
if not isinstance(doc,dict):
  raise ValueError("expected one cluster object")
def obj(value):
  if value is None:
    return {}
  if not isinstance(value,dict):
    raise ValueError("expected an object")
  return value
update="gcloud container clusters update %s %s" % (cluster,loc)
out=[]
if "nodepool-mgmt" in selected:
  channel=obj(doc.get("releaseChannel")).get("channel") or "UNSPECIFIED"
  pools=doc.get("nodePools") or []
  if not isinstance(pools,list):
    raise ValueError("nodePools must be a list")
  forced=False
  if not pools:
    out.append("I\tnodepool  no node pools reported")
  for pool in pools:
    name=obj(pool).get("name") or "?"
    mgmt=obj(pool.get("management"))
    off=[]
    flags=[]
    if mgmt.get("autoRepair") is not True:
      off.append("auto-repair")
      flags.append("--enable-autorepair")
    # A release channel keeps auto-upgrade on whatever the pool says.
    if mgmt.get("autoUpgrade") is not True:
      if channel == "UNSPECIFIED":
        off.append("auto-upgrade")
        flags.append("--enable-autoupgrade")
      else:
        forced=True
    if off:
      out.append("W\tnodepool  node pool %s: %s off" % (name," and ".join(off)))
      out.append("I\tfix       gcloud container node-pools update %s --cluster %s %s %s" % (name,cluster,loc," ".join(flags)))
    else:
      out.append("O\tnodepool  node pool %s: auto-repair and auto-upgrade on" % name)
  if forced:
    out.append("I\tnodepool  the %s release channel keeps auto-upgrade on regardless of the pool setting" % channel)
if "maintenance" in selected:
  window=obj(obj(doc.get("maintenancePolicy")).get("window"))
  recurring=obj(window.get("recurringWindow"))
  daily=obj(window.get("dailyMaintenanceWindow"))
  if recurring.get("recurrence"):
    out.append("O\tmaint     recurring window %s" % recurring["recurrence"])
  elif daily.get("startTime"):
    out.append("O\tmaint     daily window from %s" % daily["startTime"])
  else:
    out.append("W\tmaint     no maintenance window: upgrades can start at any hour")
    out.append("I\tfix       %s --maintenance-window-start START --maintenance-window-end END --maintenance-window-recurrence RRULE" % update)
if "authnets" in selected:
  nets=obj(doc.get("masterAuthorizedNetworksConfig"))
  private_endpoint=obj(doc.get("privateClusterConfig")).get("enablePrivateEndpoint") is True
  fix="I\tfix       %s --enable-master-authorized-networks --master-authorized-networks CIDR" % update
  if nets.get("enabled") is True:
    blocks=nets.get("cidrBlocks") or []
    if not isinstance(blocks,list):
      raise ValueError("cidrBlocks must be a list")
    out.append("O\tauthnets  master authorized networks on, %d CIDR block(s)" % len(blocks))
    # Only the open-world block is ever printed; the rest are counted.
    if any(obj(b).get("cidrBlock") == "0.0.0.0/0" for b in blocks):
      out.append("W\tauthnets  0.0.0.0/0 is authorized: the control plane is open to the internet")
      out.append(fix)
  elif private_endpoint:
    out.append("O\tauthnets  private endpoint only")
  else:
    out.append("W\tauthnets  public control-plane endpoint with master authorized networks off")
    out.append(fix)
if "observability" in selected:
  logging=obj(obj(doc.get("loggingConfig")).get("componentConfig")).get("enableComponents") or []
  monitoring=obj(obj(doc.get("monitoringConfig")).get("componentConfig")).get("enableComponents") or []
  missing=["logging %s" % c for c in ("SYSTEM_COMPONENTS","WORKLOADS") if c not in logging]
  missing+=["monitoring SYSTEM_COMPONENTS"] if "SYSTEM_COMPONENTS" not in monitoring else []
  if missing:
    out.append("W\tobserv    not collected: %s" % ", ".join(missing))
    out.append("I\tfix       %s --logging=SYSTEM,WORKLOAD --monitoring=SYSTEM" % update)
  else:
    out.append("O\tobserv    logging %s; monitoring %s" % (",".join(logging),",".join(monitoring)))
if "shielded" in selected:
  if obj(doc.get("shieldedNodes")).get("enabled") is True:
    out.append("O\tshielded  shielded nodes on")
  else:
    out.append("W\tshielded  shielded nodes off: node identity and boot integrity are not verified")
    out.append("I\tfix       %s --enable-shielded-nodes" % update)
if "dataplane" in selected:
  if obj(doc.get("networkConfig")).get("datapathProvider") == "ADVANCED_DATAPATH":
    out.append("O\tdataplane Dataplane V2, with network policy built in")
  elif obj(doc.get("networkPolicy")).get("enabled") is True:
    out.append("O\tdataplane network policy enforcement on")
  else:
    out.append("W\tdataplane no NetworkPolicy enforcement: policies are accepted and ignored")
    out.append("I\tfix       %s --update-addons=NetworkPolicy=ENABLED" % update)
    out.append("I\tfix       %s --enable-network-policy" % update)
    out.append("I\tdataplane Dataplane V2 can only be chosen when a cluster is created")
print("\n".join(out))
' "$json_csv" "$CLUSTER" "${loc_flag[*]}" 2>/dev/null)"; then
    err "could not parse the cluster description JSON"
    exit 1
  fi
  cluster_json=""
  while IFS=$'\t' read -r tag text; do
    case "$tag" in
      W) FINDINGS=1; warn "$text" ;;
      O) ok "$text" ;;
      I) info "$text" ;;
    esac
  done <<< "$report"
fi

if (( FINDINGS == 0 )); then
  info "next      no mutating command; re-run after a cluster change"
  exit 0
fi
exit 0
