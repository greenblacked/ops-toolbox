#!/usr/bin/env bash
# Exercise every GKE doctor check against a stubbed gcloud and cluster fixtures.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../gke_cluster_doctor.sh"
failures=0
ok() { printf '[ ok ] %s\n' "$*"; }
err() { printf '[fail] %s\n' "$*" >&2; failures=$((failures + 1)); }
assert_rc() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else err "$1 (expected exit $2, got $3): $out"; fi
}
assert_contains() {
  if [[ "$out" == *"$2"* ]]; then ok "$1"; else err "$1 (missing '$2'): $out"; fi
}
assert_absent() {
  if [[ "$out" != *"$2"* ]]; then ok "$1"; else err "$1 (unexpected '$2'): $out"; fi
}

scratch="$(mktemp -d)" || { err 'could not create fixture directory'; exit 1; }
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin"
export GKE_FIXTURE_DIR="$scratch"
GKE_CALLS="$scratch/calls"
ALL_CALLS="$scratch/all-calls"
: > "$ALL_CALLS"
export GKE_CALLS

# Each fixture is a cluster description as `gcloud ... --format=json` prints
# it, plus the answers the original checks read through --format=value(...),
# derived from the same document so the two can never disagree.
if ! python3 - "$scratch" <<'PY'
import copy, json, pathlib, sys
root=pathlib.Path(sys.argv[1])
MASTER='1.30.5-gke.1'
GOOD={
  'name':'c','currentMasterVersion':MASTER,
  'releaseChannel':{'channel':'REGULAR'},
  'nodePools':[{'name':'pool-a','version':MASTER,'management':{'autoRepair':True,'autoUpgrade':True}}],
  'workloadIdentityConfig':{'workloadPool':'p.svc.id.goog'},
  'privateClusterConfig':{'enablePrivateNodes':True,'enablePrivateEndpoint':False},
  'masterAuthorizedNetworksConfig':{'enabled':True,'cidrBlocks':[{'displayName':'office','cidrBlock':'10.0.0.0/8'}]},
  'maintenancePolicy':{'window':{'recurringWindow':{'window':{'startTime':'2026-01-03T02:00:00Z','endTime':'2026-01-03T06:00:00Z'},
                                                    'recurrence':'FREQ=WEEKLY;BYDAY=SA,SU'}}},
  'loggingConfig':{'componentConfig':{'enableComponents':['SYSTEM_COMPONENTS','WORKLOADS']}},
  'monitoringConfig':{'componentConfig':{'enableComponents':['SYSTEM_COMPONENTS']}},
  'shieldedNodes':{'enabled':True},
  'networkConfig':{'datapathProvider':'ADVANCED_DATAPATH'},
}
def value(doc, *path):
    # What gcloud --format=value(...) prints for one key: '' for a missing
    # field, True/False for a boolean, and ';' between list elements.
    def walk(node, keys):
        if not keys:
            return node
        if isinstance(node, list):
            return [walk(n, keys) for n in node]
        if not isinstance(node, dict) or keys[0] not in node:
            return None
        return walk(node[keys[0]], keys[1:])
    found=walk(doc, list(path))
    def text(v):
        if v is None:
            return ''
        if isinstance(v, bool):
            return 'True' if v else 'False'
        if isinstance(v, list):
            return ';'.join(text(x) for x in v)
        return str(v)
    return text(found)
def save(name, doc, raw=None):
    (root/(name+'.json')).write_text(raw if raw is not None else json.dumps(doc))
    lines=[
      ('value(currentMasterVersion)', value(doc,'currentMasterVersion')),
      ('value(releaseChannel.channel)', value(doc,'releaseChannel','channel')),
      ('value(nodePools.name,nodePools.version)', value(doc,'nodePools','name')+'\t'+value(doc,'nodePools','version')),
      ('value(workloadIdentityConfig.workloadPool)', value(doc,'workloadIdentityConfig','workloadPool')),
      ('value(privateClusterConfig.enablePrivateNodes)', value(doc,'privateClusterConfig','enablePrivateNodes')),
      ('value(privateClusterConfig.enablePrivateEndpoint)', value(doc,'privateClusterConfig','enablePrivateEndpoint')),
    ]
    (root/(name+'.values')).write_text(''.join('%s|%s\n' % kv for kv in lines))
def variant(name, change):
    doc=copy.deepcopy(GOOD)
    change(doc)
    save(name, doc)
save('good-cluster', GOOD)
variant('no-channel', lambda d: d.pop('releaseChannel'))
variant('pool-skew', lambda d: d['nodePools'].append({'name':'pool-b','version':'1.29.8-gke.2',
                                                       'management':{'autoRepair':True,'autoUpgrade':True}}))
variant('no-wi', lambda d: d.pop('workloadIdentityConfig'))
variant('repair-off', lambda d: d['nodePools'][0]['management'].update(autoRepair=False))
variant('upgrade-off-with-channel', lambda d: d['nodePools'][0]['management'].update(autoUpgrade=False))
def upgrade_off_no_channel(d):
    d.pop('releaseChannel')
    d['nodePools'][0]['management']['autoUpgrade']=False
variant('upgrade-off-no-channel', upgrade_off_no_channel)
variant('no-maint-window', lambda d: d.pop('maintenancePolicy'))
variant('maint-daily', lambda d: d.update(maintenancePolicy={'window':{'dailyMaintenanceWindow':{'startTime':'03:00','duration':'PT4H0M0S'}}}))
variant('authnets-off-public', lambda d: d.pop('masterAuthorizedNetworksConfig'))
def authnets_private(d):
    d.pop('masterAuthorizedNetworksConfig')
    d['privateClusterConfig']['enablePrivateEndpoint']=True
variant('authnets-off-private-endpoint', authnets_private)
variant('authnets-open-world', lambda d: d['masterAuthorizedNetworksConfig']['cidrBlocks'].append({'displayName':'anywhere','cidrBlock':'0.0.0.0/0'}))
variant('logging-system-only', lambda d: d['loggingConfig']['componentConfig'].update(enableComponents=['SYSTEM_COMPONENTS']))
variant('monitoring-missing', lambda d: d.pop('monitoringConfig'))
variant('shielded-off', lambda d: d.update(shieldedNodes={'enabled':False}))
variant('dp-v2', lambda d: None)
def netpolicy(d):
    d['networkConfig']={'datapathProvider':'LEGACY_DATAPATH'}
    d['networkPolicy']={'provider':'CALICO','enabled':True}
variant('netpolicy-on', netpolicy)
variant('dp-none', lambda d: d.update(networkConfig={}))
save('malformed', GOOD, raw='{broken')
save('empty', GOOD, raw='')
PY
then
  err 'could not generate cluster fixtures'
  exit 1
fi

# Bash builtins only, so the stub still answers on a PATH that holds nothing
# but bash and itself (the python3-missing cases below).
cat > "$scratch/bin/gcloud" <<'GCLOUD'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GKE_CALLS"
base="$GKE_FIXTURE_DIR/$GKE_CLUSTER"
for arg in "$@"; do
  case "$arg" in
    --format=json)
      if [[ -n "${GKE_JSON_FAIL:-}" ]]; then exit 1; fi
      printf '%s' "$(<"$base.json")"
      exit 0
      ;;
    --format=*)
      want="${arg#--format=}"
      while IFS='|' read -r key answer; do
        if [[ "$key" == "$want" ]]; then
          printf '%s\n' "$answer"
          exit 0
        fi
      done < "$base.values"
      printf 'unexpected format: %s\n' "$want" >&2
      exit 99
      ;;
  esac
done
printf 'unexpected stub command: %s\n' "$*" >&2
exit 99
GCLOUD
chmod +x "$scratch/bin/gcloud" || { err 'could not make gcloud stub executable'; exit 1; }

TIMEOUT_BIN="$(command -v timeout || true)"
run_with_path() {
  local path="$1"
  shift
  : > "$GKE_CALLS"
  if [[ -n "$TIMEOUT_BIN" ]]; then
    out="$(PATH="$path" "$TIMEOUT_BIN" 20 "$SCRIPT" "$@" 2>&1)"; rc=$?
  else
    out="$(PATH="$path" "$SCRIPT" "$@" 2>&1)"; rc=$?
  fi
  cat "$GKE_CALLS" >> "$ALL_CALLS"
}
run_doctor() { run_with_path "$scratch/bin:$PATH" --project p --cluster c "$@"; }
json_describes() { grep -c -- '--format=json' "$GKE_CALLS"; }

printf '\n--- A well-configured cluster ---\n'
export GKE_CLUSTER=good-cluster GKE_JSON_FAIL=''
run_doctor --location europe-west1
assert_rc 'good cluster -> exit 0' 0 "$rc"
assert_absent 'good cluster has no warning' '[warn]'
for want in 'channel   REGULAR' 'skew      node pool pool-a is 1.30.5-gke.1' 'identity  p.svc.id.goog' \
            'network   privateNodes=True privateEndpoint=False' \
            'nodepool  node pool pool-a: auto-repair and auto-upgrade on' \
            'maint     recurring window FREQ=WEEKLY;BYDAY=SA,SU' \
            'authnets  master authorized networks on, 1 CIDR block(s)' \
            'observ    logging SYSTEM_COMPONENTS,WORKLOADS; monitoring SYSTEM_COMPONENTS' \
            'shielded  shielded nodes on' 'dataplane Dataplane V2' \
            'next      no mutating command'; do
  assert_contains "good cluster reports '$want'" "$want"
done
assert_absent 'authorized CIDRs are counted, not printed' '10.0.0.0/8'
if [[ "$(json_describes)" == "1" ]]; then ok 'the six JSON checks share one describe'; else err "JSON describes: $(json_describes)"; fi
if grep -q -- '--region europe-west1 ' "$GKE_CALLS"; then ok 'a region location uses --region'; else err "no --region: $(cat "$GKE_CALLS")"; fi
run_doctor --location europe-west1-b
assert_rc 'zonal cluster -> exit 0' 0 "$rc"
if grep -q -- '--zone europe-west1-b ' "$GKE_CALLS"; then ok 'a zone location uses --zone'; else err "no --zone: $(cat "$GKE_CALLS")"; fi

printf '\n--- Each finding with the gcloud flag that fixes it ---\n'
for case_ in \
  'no-channel|channel   no release channel set|--release-channel regular' \
  'pool-skew|skew      node pool pool-b is 1.29.8-gke.2 (control plane 1.30.5-gke.1)|--node-pool pool-b --cluster-version 1.30.5-gke.1' \
  'no-wi|identity  Workload Identity is not set|--workload-pool=p.svc.id.goog' \
  'repair-off|nodepool  node pool pool-a: auto-repair off|fix       gcloud container node-pools update pool-a --cluster c --region europe-west1 --enable-autorepair' \
  'upgrade-off-no-channel|nodepool  node pool pool-a: auto-upgrade off|--enable-autoupgrade' \
  'no-maint-window|maint     no maintenance window: upgrades can start at any hour|--maintenance-window-start START --maintenance-window-end END --maintenance-window-recurrence RRULE' \
  'authnets-off-public|authnets  public control-plane endpoint with master authorized networks off|--enable-master-authorized-networks --master-authorized-networks CIDR' \
  'authnets-open-world|authnets  0.0.0.0/0 is authorized: the control plane is open to the internet|--enable-master-authorized-networks' \
  'logging-system-only|observ    not collected: logging WORKLOADS|--logging=SYSTEM,WORKLOAD --monitoring=SYSTEM' \
  'monitoring-missing|observ    not collected: monitoring SYSTEM_COMPONENTS|--monitoring=SYSTEM' \
  'shielded-off|shielded  shielded nodes off|fix       gcloud container clusters update c --region europe-west1 --enable-shielded-nodes' \
  'dp-none|dataplane no NetworkPolicy enforcement: policies are accepted and ignored|--enable-network-policy'
do
  IFS='|' read -r fixture want fix <<<"$case_"
  export GKE_CLUSTER="$fixture"
  run_doctor --location europe-west1
  assert_rc "$fixture -> exit 0 (findings do not change the exit code)" 0 "$rc"
  assert_contains "$fixture finding" "$want"
  assert_contains "$fixture fix" "$fix"
  assert_absent "$fixture does not claim a clean cluster" 'next      no mutating command'
done

for case_ in \
  'upgrade-off-with-channel|keeps auto-upgrade on regardless of the pool setting' \
  'authnets-off-private-endpoint|authnets  private endpoint only' \
  'netpolicy-on|dataplane network policy enforcement on' \
  'dp-v2|dataplane Dataplane V2' \
  'maint-daily|maint     daily window from 03:00'
do
  IFS='|' read -r fixture want <<<"$case_"
  export GKE_CLUSTER="$fixture"
  run_doctor --location europe-west1
  assert_rc "$fixture -> exit 0" 0 "$rc"
  assert_contains "$fixture is explained" "$want"
  assert_absent "$fixture is not a finding" '[warn]'
done

printf '\n--- Check selection ---\n'
export GKE_CLUSTER=shielded-off
run_doctor --location europe-west1 --only shielded
assert_contains '--only shielded runs the check' 'shielded  shielded nodes off'
assert_absent '--only shielded skips the original checks' 'channel   '
if [[ "$(json_describes)" == "1" ]]; then ok '--only shielded issues exactly one JSON describe'; else err "--only shielded JSON describes: $(json_describes)"; fi
run_doctor --location europe-west1 --only channel
if [[ "$(json_describes)" == "0" ]]; then ok '--only channel never asks for JSON'; else err "--only channel asked for JSON: $(cat "$GKE_CALLS")"; fi

out="$(PATH="$scratch/bin:$PATH" "$SCRIPT" --list-checks 2>&1)"
want_ids="channel
skew
identity
network
nodepool-mgmt
maintenance
authnets
observability
shielded
dataplane"
if [[ "$out" == "$want_ids" ]]; then ok '--list-checks prints the ten ids, original four first'; else err "unexpected --list-checks: $out"; fi
run_doctor --location europe-west1 --only nosuch
assert_rc 'unknown check id -> 3' 3 "$rc"
run_doctor --location europe-west1 --only ' shielded , dataplane '
assert_rc 'spaces around ids are ignored' 0 "$rc"
assert_contains 'spaced selection still runs dataplane' 'dataplane Dataplane V2'

printf '\n--- python3 missing ---\n'
bare_path="$(mktemp -d)"
ln -s "$BASH" "$bare_path/bash"
ln -s "$scratch/bin/gcloud" "$bare_path/gcloud"
export GKE_CLUSTER=good-cluster
run_with_path "$bare_path" --project p --cluster c --location europe-west1
assert_rc 'default selection without python3 -> exit 0' 0 "$rc"
assert_contains 'the JSON checks are skipped with a warning' 'python3 not found; skipping nodepool-mgmt maintenance authnets observability shielded dataplane'
assert_contains 'the original checks still run' 'channel   REGULAR'
if [[ "$(json_describes)" == "0" ]]; then ok 'no JSON describe without python3'; else err "JSON describe without python3: $(cat "$GKE_CALLS")"; fi
run_with_path "$bare_path" --project p --cluster c --location europe-west1 --only shielded
assert_rc '--only naming a JSON check without python3 -> exit 2' 2 "$rc"
assert_contains 'the missing interpreter is named' 'python3 is not installed'
run_with_path "$bare_path" --project p --cluster c --location europe-west1 --only channel,dataplane
assert_rc '--only mixing old and JSON checks without python3 -> exit 2' 2 "$rc"
run_with_path "$bare_path" --project p --cluster c --location europe-west1 --only channel
assert_rc '--only with original checks needs no python3' 0 "$rc"
rm -rf "$bare_path"

printf '\n--- A description that cannot be read ---\n'
for fixture in malformed empty; do
  export GKE_CLUSTER="$fixture"
  run_doctor --location europe-west1
  assert_rc "$fixture JSON -> exit 1" 1 "$rc"
  assert_contains "$fixture JSON is named" 'could not parse the cluster description JSON'
done
export GKE_CLUSTER=good-cluster GKE_JSON_FAIL=1
run_doctor --location europe-west1
assert_rc 'a failing JSON describe -> exit 1' 1 "$rc"
assert_contains 'the failing describe is named' 'describe --format=json failed'
export GKE_JSON_FAIL=''

printf '\n--- Read-only ---\n'
if [[ ! -s "$ALL_CALLS" ]]; then
  err 'no gcloud call was recorded; the read-only check would pass vacuously'
elif grep -Evq '^--project p container clusters describe c --(region|zone) [^ ]+ --format=.+$' "$ALL_CALLS"; then
  err "gcloud ran something other than clusters describe: $(grep -Ev '^--project p container clusters describe c --(region|zone) [^ ]+ --format=.+$' "$ALL_CALLS" | head -3)"
else
  ok 'gcloud only ever ran container clusters describe; every fix stays printed text'
fi

printf '\nGKE doctor failures: %s\n' "$failures"
(( failures == 0 ))
