#!/usr/bin/env bash
# Exercise workload triage (rollouts, autoscalers, Jobs) with secret-free kubectl fixtures.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../kubectl_workload_diag.sh"
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
export WL_FIXTURE_DIR="$scratch"
WL_CALLS="$scratch/calls"
ALL_CALLS="$scratch/all-calls"
: > "$ALL_CALLS"
export WL_CALLS

# Controller status shapes as the API reports them. Every kubectl invocation
# stays inside the stub below; nothing contacts a cluster.
if ! python3 - "$scratch" <<'PY'
import json, pathlib, sys
root=pathlib.Path(sys.argv[1])
def save(name, items):
    (root/(name+'.json')).write_text(json.dumps({'items':items}))
def meta(name, **extra):
    doc={'namespace':'demo','name':name}
    doc.update(extra)
    return doc
def deploy(name='api', replicas=3, available=3, generation=2, observed=2, paused=False, progressing=None):
    spec={'replicas':replicas}
    if paused:
        spec['paused']=True
    conds=[{'type':'Available','status':'True' if available >= replicas else 'False'},
           progressing or {'type':'Progressing','status':'True','reason':'NewReplicaSetAvailable'}]
    return {'metadata':meta(name,generation=generation),'spec':spec,
            'status':{'observedGeneration':observed,'replicas':replicas,'availableReplicas':available,'conditions':conds}}
def sts(name='db', replicas=3, ready=3, updated=3, current='db-1', target='db-1', partition=None, strategy='RollingUpdate'):
    spec={'replicas':replicas,'updateStrategy':{'type':strategy} if strategy else {}}
    if partition is not None:
        spec['updateStrategy']['rollingUpdate']={'partition':partition}
    return {'metadata':meta(name),'spec':spec,
            'status':{'replicas':replicas,'readyReplicas':ready,'updatedReplicas':updated,
                      'currentRevision':current,'updateRevision':target}}
def ds(name='agent', desired=3, ready=3, unavailable=0, misscheduled=0):
    status={'desiredNumberScheduled':desired,'numberReady':ready,'numberMisscheduled':misscheduled}
    if unavailable:
        status['numberUnavailable']=unavailable
    return {'metadata':meta(name),'spec':{},'status':status}
def hpa(name='web', current=2, maximum=5, active=None, able=None):
    conds=[able or {'type':'AbleToScale','status':'True','reason':'ReadyForNewScale'},
           active or {'type':'ScalingActive','status':'True','reason':'ValidMetricFound'}]
    return {'metadata':meta(name),'spec':{'minReplicas':1,'maxReplicas':maximum},
            'status':{'currentReplicas':current,'desiredReplicas':current,'conditions':conds}}
def job(name='migrate', conds=None, failed=0, **extra):
    status={'conditions':conds or []}
    if failed:
        status['failed']=failed
    return {'metadata':meta(name,**extra),'spec':{'backoffLimit':6},'status':status}
save('empty', [])
save('deploy-healthy', [deploy(), deploy('idle',replicas=0,available=0)])
save('deploy-deadline', [deploy(available=2,progressing={'type':'Progressing','status':'False','reason':'ProgressDeadlineExceeded','message':'ReplicaSet "api-7d9f8" has timed out progressing.'})])
save('deploy-stale-generation', [deploy(generation=3,observed=2)])
save('deploy-paused', [deploy(paused=True,progressing={'type':'Progressing','status':'Unknown','reason':'DeploymentPaused'})])
save('deploy-unavailable', [deploy(available=1)])
save('deploy-zero-replicas', [deploy('idle',replicas=0,available=0,progressing={'type':'Progressing','status':'False','reason':'ProgressDeadlineExceeded'})])
save('sts-healthy', [sts()])
save('sts-notready', [sts(ready=1)])
save('sts-stuck-update', [sts(updated=1,target='db-2')])
save('sts-partitioned', [sts(updated=1,target='db-2',partition=2)])
save('sts-partition-done', [sts(updated=2,target='db-2',partition=1)])
save('sts-partition-over', [sts(updated=0,target='db-2',partition=3)])
save('sts-partition-stuck', [sts(updated=0,target='db-2',partition=1)])
save('sts-ondelete', [sts(updated=0,target='db-2',strategy='OnDelete')])
save('sts-no-type', [sts(updated=1,target='db-2',strategy=None)])
save('ds-healthy', [ds()])
save('ds-unavailable', [ds(ready=2,unavailable=1)])
save('ds-misscheduled', [ds(misscheduled=1)])
save('hpa-ok', [hpa()])
save('hpa-metrics-fail', [hpa(active={'type':'ScalingActive','status':'False','reason':'FailedGetResourceMetric',
                                      'message':'the HPA was unable to compute the replica count: failed to get cpu utilization'})])
save('hpa-at-max', [hpa(current=5)])
save('hpa-scaled-to-zero', [hpa(current=0,active={'type':'ScalingActive','status':'False','reason':'ScalingDisabled',
                                                  'message':'scaling is disabled since the replica count of the target is zero'})])
save('job-ok', [job(conds=[{'type':'Complete','status':'True'}]), job('running')])
save('job-failed', [job(conds=[{'type':'Failed','status':'True','reason':'BackoffLimitExceeded'}],failed=6)])
save('job-complete', [job(conds=[{'type':'Complete','status':'True'},{'type':'Failed','status':'False'}])])
save('job-deleting', [job(conds=[{'type':'Failed','status':'True','reason':'DeadlineExceeded'}],deletionTimestamp='2026-10-01T10:00:00Z')])
(root/'malformed.json').write_text('{broken')
(root/'missing-items.json').write_text('{}')
(root/'invalid-items.json').write_text('{"items":{}}')
(root/'invalid-entry.json').write_text('{"items":[null]}')
PY
then
  err 'could not generate JSON fixtures'
  exit 1
fi

cat > "$scratch/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "$WL_CALLS"
case " $* " in
  *" cluster-info "*) exit 0 ;;
  *" get deployments "*) resource=deployments; fixture="$WL_DEPLOYMENTS" ;;
  *" get statefulsets "*) resource=statefulsets; fixture="$WL_STATEFULSETS" ;;
  *" get daemonsets "*) resource=daemonsets; fixture="$WL_DAEMONSETS" ;;
  *" get hpa "*) resource=hpa; fixture="$WL_HPA" ;;
  *" get jobs "*) resource=jobs; fixture="$WL_JOBS" ;;
  *) printf 'unexpected stub command: %s\n' "$*" >&2; exit 99 ;;
esac
if [[ "$resource" == "$WL_FAIL_RESOURCE" ]]; then exit 1; fi
if [[ "$resource" == "$WL_EMPTY_RESOURCE" ]]; then exit 0; fi
if [[ "$resource" == "$WL_BAD_RESOURCE" ]]; then fixture="$WL_BAD_FIXTURE"; fi
cat "$WL_FIXTURE_DIR/$fixture.json"
KUBECTL
chmod +x "$scratch/kubectl" || { err 'could not make kubectl stub executable'; exit 1; }

TIMEOUT_BIN="$(command -v timeout || true)"
run_wl() {
  : > "$WL_CALLS"
  if [[ -n "$TIMEOUT_BIN" ]]; then
    out="$(PATH="$scratch:$PATH" "$TIMEOUT_BIN" 20 "$SCRIPT" "$@" 2>&1)"; rc=$?
  else
    out="$(PATH="$scratch:$PATH" "$SCRIPT" "$@" 2>&1)"; rc=$?
  fi
  cat "$WL_CALLS" >> "$ALL_CALLS"
}
reset_fixtures() {
  export WL_DEPLOYMENTS=deploy-healthy WL_STATEFULSETS=sts-healthy WL_DAEMONSETS=ds-healthy
  export WL_HPA=hpa-ok WL_JOBS=job-ok
  export WL_FAIL_RESOURCE='' WL_EMPTY_RESOURCE='' WL_BAD_RESOURCE='' WL_BAD_FIXTURE=malformed
}

printf '\n--- Healthy and deliberately idle workloads ---\n'
reset_fixtures
run_wl
assert_rc 'healthy workloads -> quiet exit 4' 4 "$rc"
assert_contains 'healthy summary' 'workloads look quiet'
assert_absent 'healthy workloads produce no warning' '[warn]'
assert_contains 'sections are headed like the pod diag' '== Deployments =='
for resource in deployments statefulsets daemonsets hpa jobs; do
  if [[ "$(cat "$WL_CALLS")" == *"get $resource --all-namespaces -o json"* ]]; then
    ok "default run lists $resource across every namespace"
  else
    err "default run did not list $resource with --all-namespaces: $(cat "$WL_CALLS")"
  fi
done

for case_ in \
  "WL_DEPLOYMENTS|deploy-zero-replicas" \
  "WL_STATEFULSETS|sts-partitioned" \
  "WL_STATEFULSETS|sts-partition-done" \
  "WL_STATEFULSETS|sts-partition-over" \
  "WL_STATEFULSETS|sts-ondelete" \
  "WL_HPA|hpa-scaled-to-zero" \
  "WL_JOBS|job-complete" \
  "WL_JOBS|job-deleting"
do
  IFS='|' read -r var fixture <<<"$case_"
  reset_fixtures
  export "$var=$fixture"
  run_wl
  assert_rc "$fixture stays quiet" 4 "$rc"
  assert_absent "$fixture produces no warning" '[warn]'
done

printf '\n--- Each stuck controller is a finding with a printed next step ---\n'
for case_ in \
  "WL_DEPLOYMENTS|deploy-deadline|deployment demo/api: ProgressDeadlineExceeded (2/3 available)|kubectl rollout undo deployment/api -n demo" \
  "WL_DEPLOYMENTS|deploy-stale-generation|deployment demo/api: spec generation 3 not observed yet, controller at 2 (3/3 available)|kubectl rollout status deployment/api -n demo" \
  "WL_DEPLOYMENTS|deploy-paused|deployment demo/api: rollout paused (3/3 available)|kubectl rollout resume deployment/api -n demo" \
  "WL_DEPLOYMENTS|deploy-unavailable|deployment demo/api: replicas unavailable (1/3 available)|kubectl rollout status deployment/api -n demo" \
  "WL_STATEFULSETS|sts-notready|statefulset demo/db: 1/3 ready|kubectl rollout status statefulset/db -n demo" \
  "WL_STATEFULSETS|sts-stuck-update|statefulset demo/db: update to db-2 stuck (1/3 updated)|kubectl rollout status statefulset/db -n demo" \
  "WL_STATEFULSETS|sts-partition-stuck|statefulset demo/db: update to db-2 stuck (0/2 updated)|kubectl rollout status statefulset/db -n demo" \
  "WL_STATEFULSETS|sts-no-type|statefulset demo/db: update to db-2 stuck (1/3 updated)|kubectl rollout status statefulset/db -n demo" \
  "WL_DAEMONSETS|ds-unavailable|daemonset demo/agent: 2/3 ready, 1 unavailable|kubectl rollout status daemonset/agent -n demo" \
  "WL_DAEMONSETS|ds-misscheduled|daemonset demo/agent: 1 misscheduled|kubectl describe daemonset agent -n demo" \
  "WL_HPA|hpa-metrics-fail|hpa demo/web: ScalingActive=False FailedGetResourceMetric: the HPA was unable to compute the replica count|kubectl describe hpa web -n demo" \
  "WL_HPA|hpa-at-max|hpa demo/web: at max 5|kubectl describe hpa web -n demo" \
  "WL_JOBS|job-failed|job demo/migrate: BackoffLimitExceeded (6 failed pod(s))|kubectl describe job migrate -n demo"
do
  IFS='|' read -r var fixture want next <<<"$case_"
  reset_fixtures
  export "$var=$fixture"
  run_wl
  assert_rc "$fixture -> findings exit 0" 0 "$rc"
  assert_contains "$fixture reason" "$want"
  assert_contains "$fixture next step is printed" "next      $next"
  assert_absent "$fixture does not claim quiet" 'workloads look quiet'
done

reset_fixtures
export WL_DEPLOYMENTS=deploy-deadline
run_wl --context fixture-context --namespace demo
assert_rc 'context run reports the stuck rollout' 0 "$rc"
assert_contains 'next step names the context that was read' \
  'next      kubectl --context fixture-context rollout status deployment/api -n demo'
if [[ "$(cat "$WL_CALLS")" == *'--context fixture-context get deployments --namespace demo -o json'* ]]; then
  ok '--context and --namespace reach every get'
else
  err "--context/--namespace not passed through: $(cat "$WL_CALLS")"
fi

printf '\n--- Check selection ---\n'
bare_path="$(mktemp -d)"
ln -s "$BASH" "$bare_path/bash"
if [[ -n "$TIMEOUT_BIN" ]]; then
  out="$(PATH="$bare_path" "$TIMEOUT_BIN" 20 "$SCRIPT" --list-checks 2>&1)"; rc=$?
else
  out="$(PATH="$bare_path" "$SCRIPT" --list-checks 2>&1)"; rc=$?
fi
assert_rc '--list-checks answers without kubectl' 0 "$rc"
for id in deployments statefulsets daemonsets hpa jobs; do
  assert_contains "--list-checks prints $id" "$id"
done
if [[ -n "$TIMEOUT_BIN" ]]; then
  out="$(PATH="$bare_path" "$TIMEOUT_BIN" 20 "$SCRIPT" 2>&1)"; rc=$?
else
  out="$(PATH="$bare_path" "$SCRIPT" 2>&1)"; rc=$?
fi
assert_rc 'missing kubectl -> exit 2' 2 "$rc"
rm -rf "$bare_path"

reset_fixtures
export WL_HPA=hpa-at-max
run_wl --only hpa
assert_rc '--only hpa reports the autoscaler' 0 "$rc"
gets="$(grep -cE '(^| )get ' "$WL_CALLS")"
if [[ "$gets" == "1" && "$(cat "$WL_CALLS")" == *'get hpa '* ]]; then
  ok '--only hpa issues exactly one get'
else
  err "--only hpa issued $gets get call(s): $(cat "$WL_CALLS")"
fi
assert_absent '--only hpa skips the other sections' '== Deployments =='

reset_fixtures
run_wl --only=jobs,deployments
gets="$(grep -cE '(^| )get ' "$WL_CALLS")"
if [[ "$gets" == "2" ]]; then ok '--only=jobs,deployments issues two gets'; else err "--only=jobs,deployments issued $gets gets"; fi
assert_rc '--only with healthy workloads -> 4' 4 "$rc"

run_wl --only nosuch
assert_rc '--only with an unknown id -> 3' 3 "$rc"
run_wl --only ,
assert_rc '--only selecting nothing -> 3' 3 "$rc"
if [[ ! -s "$WL_CALLS" ]]; then ok 'a rejected --only never reaches kubectl'; else err "rejected --only called kubectl: $(cat "$WL_CALLS")"; fi

printf '\n--- Failed queries and malformed JSON across every section ---\n'
for resource in deployments statefulsets daemonsets hpa jobs; do
  for mode in query empty malformed missing-items invalid-items invalid-entry; do
    reset_fixtures
    case "$mode" in
      query) export WL_FAIL_RESOURCE="$resource" ;;
      empty) export WL_EMPTY_RESOURCE="$resource" ;;
      *) export WL_BAD_RESOURCE="$resource" WL_BAD_FIXTURE="$mode" ;;
    esac
    run_wl
    assert_rc "$resource $mode -> incomplete check exit 1" 1 "$rc"
    assert_contains "$resource $mode reported" 'could not'
    assert_contains "$resource $mode incomplete summary" 'workload check incomplete'
    assert_absent "$resource $mode cannot claim quiet" 'workloads look quiet'
    if [[ "$(cat "$WL_CALLS")" == *'get jobs'* ]]; then
      ok "$resource $mode keeps checking remaining sections"
    else
      err "$resource $mode stopped early: $(cat "$WL_CALLS")"
    fi
  done
done
reset_fixtures
export WL_DEPLOYMENTS=deploy-deadline WL_FAIL_RESOURCE=jobs
run_wl
assert_contains 'findings survive a later failed query' 'ProgressDeadlineExceeded'
assert_rc 'query failure takes precedence over findings' 1 "$rc"

printf '\n--- Read-only ---\n'
if [[ ! -s "$ALL_CALLS" ]]; then
  err 'no kubectl call was recorded; the read-only check would pass vacuously'
elif grep -Eq '(^| )(create|patch|delete|apply|rollout|scale|edit|replace|label|annotate|set)( |$)' "$ALL_CALLS"; then
  err "a mutating kubectl verb was executed: $(grep -E '(^| )(create|patch|delete|apply|rollout|scale|edit|replace|label|annotate|set)( |$)' "$ALL_CALLS" | head -3)"
else
  ok 'only get and cluster-info were ever executed; next steps stay printed text'
fi

printf '\nWorkload diagnostic failures: %s\n' "$failures"
(( failures == 0 ))
