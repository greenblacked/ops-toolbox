#!/usr/bin/env bash
# Exercise Pod diagnostic health reporting with secret-free kubectl fixtures.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../kubectl_pod_diag.sh"
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
export DIAG_FIXTURE_DIR="$scratch"
DIAG_CALLS="$scratch/calls"
export DIAG_CALLS

# Generate realistic container states and timestamps once, independently of the
# script under test. Every kubectl invocation stays inside this stub.
if ! python3 - "$scratch" <<'PY'
import copy, datetime, json, pathlib, sys
root=pathlib.Path(sys.argv[1])
now=datetime.datetime.now(datetime.timezone.utc)
recent=(now-datetime.timedelta(minutes=5)).isoformat()
old=(now-datetime.timedelta(hours=2)).isoformat()
def save(name, items):
    (root/(name+'.json')).write_text(json.dumps({'items':items}))
def container(name, ready=True, state=None):
    return {'name':name,'ready':ready,'state':state or {'running':{}},'restartCount':0}
def pod(name='api', phase='Running', regular=None, init=None, sidecar=False):
    doc={'metadata':{'namespace':'demo','name':name},'status':{'phase':phase,
         'containerStatuses':regular if regular is not None else [container('api')]}}
    if init is not None:
        doc['status']['initContainerStatuses']=init
        doc['spec']={'initContainers':[{'name':c['name'], **({'restartPolicy':'Always'} if sidecar else {})} for c in init]}
    return doc
crash={'waiting':{'reason':'CrashLoopBackOff'}}
failed={'terminated':{'exitCode':1,'reason':'Error'}}
completed={'terminated':{'exitCode':0,'reason':'Completed'}}
save('empty', [])
save('healthy', [pod(), pod('job','Succeeded',regular=[container('job',False,completed)]),
                 pod('initialized',init=[container('setup',False,completed)]),
                 pod('sidecar-ready',init=[container('proxy')],sidecar=True)])
save('unready', [pod(regular=[container('api',False)])])
save('regular-crash', [pod(regular=[container('api'),container('worker',False,crash)])])
save('init-crash', [pod(init=[container('setup',False,crash)])])
save('init-failed', [pod(phase='Pending',init=[container('setup',False,failed)])])
save('sidecar-crash', [pod(init=[container('proxy',False,crash)],sidecar=True)])
save('sidecar-unready', [pod(init=[container('proxy',False)],sidecar=True)])
save('sidecar-terminated', [pod(init=[container('proxy',False,completed)],sidecar=True)])
save('multi-crash', [pod(regular=[container('api',False,crash)],init=[container('setup',False,crash)])])
save('pending', [pod(phase='Pending',regular=[])])
save('failed', [pod(phase='Failed',regular=[container('api',False,failed)])])
minutes_ago=lambda m: (now-datetime.timedelta(minutes=m)).isoformat()
def restarted(name, count, last=None, limit=None, state=None, ready=True):
    cs=container(name, ready, state)
    cs['restartCount']=count
    if last is not None:
        cs['lastState']={'terminated':last}
    doc=pod(regular=[cs])
    doc['spec']={'containers':[{'name':name,'resources':{'limits':{'memory':limit}} if limit else {}}]}
    return doc
oom=lambda finished: {'reason':'OOMKilled','exitCode':137,'finishedAt':finished}
save('oom-recent', [restarted('api',3,oom(minutes_ago(7)),'256Mi')])
save('oom-old', [restarted('api',1,oom(minutes_ago(180)),'256Mi')])
save('oom-bad-time', [restarted('api',1,oom('invalid'),'256Mi')])
save('restarts-many', [restarted('api',9)])
save('restarts-few', [restarted('api',2)])
save('crash-many', [restarted('api',30,oom(minutes_ago(2)),'256Mi',crash,False)])
def init_restarted(count, last, limit, sidecar):
    cs=container('proxy')
    cs['restartCount']=count
    if last is not None:
        cs['lastState']={'terminated':last}
    doc=pod(init=[cs],sidecar=sidecar)
    doc['spec']['initContainers'][0]['resources']={'limits':{'memory':limit}}
    return doc
save('sidecar-oom', [init_restarted(7,oom(minutes_ago(7)),'128Mi',True)])
save('init-restarts-plain', [init_restarted(9,oom(minutes_ago(7)),'128Mi',False)])
save('restart-count-invalid', [restarted('api','many')])
save('pvc-unbound', [{'metadata':{'namespace':'demo','name':'data'},'status':{'phase':'Pending'}}])
save('node-pressure', [{'metadata':{'name':'node-demo'},'status':{'conditions':[{'type':'DiskPressure','status':'True','message':'fixture pressure'}]}}])
def event(name, **fields):
    doc={'metadata':{'namespace':'demo','creationTimestamp':old},'type':'Warning',
         'involvedObject':{'name':name},'reason':'FixtureWarning','message':name}
    doc.update(fields)
    return doc
save('series-recent', [event('fresh-series',eventTime=old,lastTimestamp=old,series={'lastObservedTime':recent})])
save('series-old', [event('old-series',eventTime=recent,lastTimestamp=recent,series={'lastObservedTime':old})])
save('last-recent', [event('fresh-last',eventTime=old,lastTimestamp=recent)])
save('last-old', [event('old-last',eventTime=recent,lastTimestamp=old)])
save('deprecated-recent', [event('fresh-deprecated',eventTime=old,deprecatedLastTimestamp=recent)])
save('event-recent', [event('fresh-event',eventTime=recent)])
save('creation-recent', [event('fresh-creation',metadata={'namespace':'demo','creationTimestamp':recent})])
save('invalid-series-fallback', [event('fresh-fallback',series={'lastObservedTime':'invalid'},lastTimestamp=recent,eventTime=old)])
save('invalid-last-fallback', [event('fresh-event-fallback',lastTimestamp='invalid',eventTime=recent)])
save('invalid-time', [event('unknown-time',eventTime='invalid',metadata={'namespace':'demo'})])
save('missing-time', [event('missing-time',metadata={'namespace':'demo'})])
save('naive-time', [event('naive-time',eventTime='2026-10-01T10:00:00',metadata={'namespace':'demo'})])
save('all-old', [event('old-event',eventTime=old)])
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
printf '%s\n' "$*" >> "$DIAG_CALLS"
case " $* " in
  *" cluster-info "*) exit 0 ;;
  *" get pods "*) resource=pods; fixture="$DIAG_PODS" ;;
  *" get events "*) resource=events; fixture="$DIAG_EVENTS" ;;
  *" get pvc "*) resource=pvc; fixture="$DIAG_PVC" ;;
  *" get nodes "*) resource=nodes; fixture="$DIAG_NODES" ;;
  *" logs "*) printf 'fixture container log\n'; exit 0 ;;
  *) printf 'unexpected stub command: %s\n' "$*" >&2; exit 99 ;;
esac
if [[ "$resource" == "$DIAG_FAIL_RESOURCE" ]]; then exit 1; fi
if [[ "$resource" == "$DIAG_EMPTY_RESOURCE" ]]; then exit 0; fi
if [[ "$resource" == "$DIAG_BAD_RESOURCE" ]]; then fixture="$DIAG_BAD_FIXTURE"; fi
cat "$DIAG_FIXTURE_DIR/$fixture.json"
KUBECTL
chmod +x "$scratch/kubectl" || { err 'could not make kubectl stub executable'; exit 1; }

TIMEOUT_BIN="$(command -v timeout || true)"
run_diag() {
  : > "$DIAG_CALLS"
  if [[ -n "$TIMEOUT_BIN" ]]; then
    out="$(PATH="$scratch:$PATH" "$TIMEOUT_BIN" 20 "$SCRIPT" "$@" 2>&1)"; rc=$?
  else
    out="$(PATH="$scratch:$PATH" "$SCRIPT" "$@" 2>&1)"; rc=$?
  fi
}
reset_fixtures() {
  export DIAG_PODS=healthy DIAG_EVENTS=empty DIAG_PVC=empty DIAG_NODES=empty
  export DIAG_FAIL_RESOURCE='' DIAG_EMPTY_RESOURCE='' DIAG_BAD_RESOURCE='' DIAG_BAD_FIXTURE=malformed
}

printf '\n--- Pod health and named container logs ---\n'
reset_fixtures
run_diag
assert_rc 'healthy Running/Succeeded/completed init/ready sidecar -> quiet exit 4' 4 "$rc"
assert_contains 'healthy summary' 'cluster looks quiet'
assert_absent 'healthy workloads produce no warning' '[warn]'
if [[ "$(cat "$DIAG_CALLS")" != *'logs '* ]]; then ok 'healthy workloads do not fetch logs'; else err 'healthy workloads fetched logs'; fi

for fixture in unready regular-crash init-crash init-failed sidecar-crash sidecar-unready sidecar-terminated multi-crash pending failed; do
  reset_fixtures
  export DIAG_PODS="$fixture"
  run_diag --context fixture-context --namespace demo
  assert_rc "$fixture -> findings exit 0" 0 "$rc"
  assert_absent "$fixture does not claim quiet health" 'cluster looks quiet'
  calls="$(cat "$DIAG_CALLS")"
  case "$fixture" in
    unready) assert_contains 'unready regular container is identified' 'container api: NotReady' ;;
    regular-crash)
      assert_contains 'crashing regular container is identified' 'container worker: CrashLoopBackOff'
      if [[ "$calls" == *'--context fixture-context logs -n demo api -c worker --previous --tail=40'* ]]; then
        ok 'previous logs target worker'
      else
        err "wrong worker logs: $calls"
      fi
      ;;
    init-crash|sidecar-crash)
      container=setup; [[ "$fixture" == 'sidecar-crash' ]] && container=proxy
      assert_contains "$fixture identifies its container" "$container: CrashLoopBackOff"
      if [[ "$calls" == *"logs -n demo api -c $container --previous --tail=40"* ]]; then
        ok "$fixture previous logs target $container"
      else
        err "wrong $fixture logs: $calls"
      fi
      ;;
    init-failed)
      assert_contains 'failed init container is identified' 'init container setup: Error'
      if [[ "$calls" == *'logs -n demo api -c setup --tail=40'* && "$calls" != *'--previous'* ]]; then
        ok 'failed init current logs target setup'
      else
        err "wrong failed init logs: $calls"
      fi
      ;;
    sidecar-unready) assert_contains 'unready restartable sidecar is identified' 'sidecar proxy: NotReady' ;;
    sidecar-terminated) assert_contains 'terminated restartable sidecar is unhealthy' 'sidecar proxy: Completed' ;;
    multi-crash)
      if [[ "$calls" == *'logs -n demo api -c api --previous --tail=40'* && "$calls" == *'logs -n demo api -c setup --previous --tail=40'* ]]; then
        ok 'both failing containers receive targeted logs'
      else
        err "wrong multi-container logs: $calls"
      fi
      ;;
    pending) assert_contains 'Pending phase remains a finding' 'pod demo/api: Pending' ;;
    failed)
      assert_contains 'failed regular container is identified' 'container api: Error'
      if [[ "$calls" == *'logs -n demo api -c api --tail=40'* && "$calls" != *'--previous'* ]]; then
        ok 'failed regular current logs target api'
      else
        err "wrong failed regular logs: $calls"
      fi
      ;;
  esac
done

printf '\n--- Restarts and OOM kills in containers that look healthy now ---\n'
reset_fixtures
export DIAG_PODS=oom-recent
run_diag
assert_rc 'recent OOM kill in a Ready container -> findings exit 0' 0 "$rc"
assert_contains 'OOM kill is named' 'last OOMKilled'
assert_contains 'restart count is shown' 'container api restarted 3x'
assert_contains 'memory limit is shown' '(memory limit 256Mi)'
assert_contains 'previous logs are suggested, not fetched' 'next      kubectl logs -n demo api -c api --previous'
assert_absent 'OOM kill is not quiet' 'cluster looks quiet'
pod_gets="$(grep -c 'get pods' "$DIAG_CALLS")"
if [[ "$pod_gets" == "1" ]]; then
  ok 'restart section reuses the pod listing (one get pods)'
else
  err "restart section listed pods $pod_gets times: $(cat "$DIAG_CALLS")"
fi
if [[ "$(cat "$DIAG_CALLS")" != *'logs '* ]]; then
  ok 'restart findings fetch no logs'
else
  err "restart findings fetched logs: $(cat "$DIAG_CALLS")"
fi

reset_fixtures
export DIAG_PODS=oom-old
run_diag
assert_rc 'OOM kill older than the default lookback -> quiet exit 4' 4 "$rc"
run_diag --since 6h
assert_rc 'wider --since includes the older OOM kill' 0 "$rc"
assert_contains 'older OOM kill reported under --since 6h' 'container api restarted 1x, last OOMKilled'
assert_contains 'restart heading names the lookback and threshold' 'Restarts and OOM kills (last 6h, threshold 5)'

reset_fixtures
export DIAG_PODS=restarts-many
run_diag
assert_rc 'restart loop above the default threshold -> findings exit 0' 0 "$rc"
assert_contains 'restart loop names its count' 'container api restarted 9x (>= 5)'
assert_contains 'restart loop suggests the previous logs' 'next      kubectl logs -n demo api -c api --previous'
run_diag --restarts 10
assert_rc '--restarts 10 lifts the threshold above 9 restarts' 4 "$rc"
run_diag --restarts=9 --context fixture-context
assert_rc '--restarts=9 reports exactly at the threshold' 0 "$rc"
assert_contains 'next step names the context that was read' 'next      kubectl --context fixture-context logs -n demo api -c api --previous'

reset_fixtures
export DIAG_PODS=sidecar-oom
run_diag
assert_rc 'OOM-killed restartable sidecar -> findings exit 0' 0 "$rc"
assert_contains 'the sidecar restart is named' 'container proxy restarted 7x'
assert_contains 'the sidecar OOM kill is named' 'last OOMKilled'
assert_contains 'the sidecar memory limit is shown' '(memory limit 128Mi)'
assert_contains 'the sidecar previous logs are suggested' 'next      kubectl logs -n demo api -c proxy --previous'
reset_fixtures
export DIAG_PODS=init-restarts-plain
run_diag
assert_rc 'a plain init container is not a restart finding' 4 "$rc"
reset_fixtures
export DIAG_PODS=restarts-few
run_diag
assert_rc 'a few restarts below the threshold -> quiet exit 4' 4 "$rc"

reset_fixtures
export DIAG_PODS=crash-many
run_diag
assert_rc 'crash loop stays a finding' 0 "$rc"
assert_contains 'crash loop is reported by the unhealthy section' 'container api: CrashLoopBackOff'
assert_absent 'crash loop is not reported twice' 'restarted 30x'

reset_fixtures
export DIAG_PODS=oom-bad-time
run_diag
assert_rc 'unreadable OOM time below the threshold is not fatal' 4 "$rc"

reset_fixtures
export DIAG_PODS=restart-count-invalid
run_diag
assert_rc 'non-numeric restartCount -> incomplete exit 1' 1 "$rc"
assert_contains 'restart parse failure is named' 'could not parse restart data'
assert_absent 'restart parse failure cannot claim quiet health' 'cluster looks quiet'

printf '\n--- Warning event last observation and fallbacks ---\n'
for fixture in series-recent last-recent deprecated-recent event-recent creation-recent invalid-series-fallback invalid-last-fallback; do
  reset_fixtures
  export DIAG_EVENTS="$fixture"
  run_diag --since 30m
  assert_rc "$fixture recent observation -> findings exit 0" 0 "$rc"
  assert_contains "$fixture Warning rendered" 'FixtureWarning'
  assert_absent "$fixture is not quietly healthy" 'cluster looks quiet'
done
for fixture in series-old last-old all-old; do
  reset_fixtures
  export DIAG_EVENTS="$fixture"
  run_diag --since 30m
  assert_rc "$fixture stale last observation -> quiet exit 4" 4 "$rc"
  assert_absent "$fixture Warning excluded" 'FixtureWarning'
done
for fixture in invalid-time missing-time naive-time; do
  reset_fixtures
  export DIAG_EVENTS="$fixture"
  run_diag
  assert_rc "$fixture unknown observation -> error exit 1" 1 "$rc"
  assert_contains "$fixture actionable timestamp diagnostic" 'could not parse events JSON or Warning observation timestamps'
  assert_absent "$fixture cannot claim quiet health" 'cluster looks quiet'
done

printf '\n--- Failed queries and malformed JSON across every section ---\n'
for resource in pods events pvc nodes; do
  for mode in query empty malformed missing-items invalid-items invalid-entry; do
    reset_fixtures
    case "$mode" in
      query) export DIAG_FAIL_RESOURCE="$resource" ;;
      empty) export DIAG_EMPTY_RESOURCE="$resource" ;;
      *) export DIAG_BAD_RESOURCE="$resource" DIAG_BAD_FIXTURE="$mode" ;;
    esac
    run_diag
    assert_rc "$resource $mode -> incomplete check exit 1" 1 "$rc"
    assert_contains "$resource $mode reported" 'could not'
    assert_contains "$resource $mode incomplete summary" 'health check incomplete'
    assert_absent "$resource $mode cannot claim quiet health" 'cluster looks quiet'
    calls="$(cat "$DIAG_CALLS")"
    if [[ "$calls" == *'get nodes -o json'* ]]; then
      ok "$resource $mode keeps checking remaining sections"
    else
      err "$resource $mode stopped early: $calls"
    fi
  done
done
reset_fixtures
export DIAG_FAIL_RESOURCE=pods
run_diag
listed="$(grep -c 'could not list pods' <<<"$out")"
if [[ "$listed" == "1" ]]; then
  ok 'a failed pod listing is reported once, not again by the restart section'
else
  err "a failed pod listing was reported $listed times: $out"
fi
assert_contains 'restart section says why it was skipped' 'skipped; the pod listing above could not be read'
reset_fixtures
export DIAG_BAD_RESOURCE=pods DIAG_BAD_FIXTURE=malformed
run_diag
if [[ "$out" != *'could not parse restart data'* ]]; then
  ok 'malformed pods JSON is counted once'
else
  err "malformed pods JSON was counted twice: $out"
fi
reset_fixtures
export DIAG_PODS=unready DIAG_FAIL_RESOURCE=events
run_diag
assert_contains 'findings survive a later failed query' 'container api: NotReady'
assert_rc 'query failure takes precedence over findings' 1 "$rc"
reset_fixtures
export DIAG_PVC=pvc-unbound DIAG_NODES=node-pressure
run_diag
assert_rc 'PVC/node findings remain supported' 0 "$rc"
assert_contains 'unbound PVC is reported' 'pvc demo/data: Pending'
assert_contains 'node pressure is reported' 'node node-demo: DiskPressure'

printf '\nPod diagnostic failures: %s\n' "$failures"
(( failures == 0 ))
