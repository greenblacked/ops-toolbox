#!/usr/bin/env bash
# Exercise the node capacity report with secret-free kubectl fixtures.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../kubectl_node_capacity.sh"
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
export CAP_FIXTURE_DIR="$scratch"
CAP_CALLS="$scratch/calls"
ALL_CALLS="$scratch/all-calls"
: > "$ALL_CALLS"
export CAP_CALLS

# Quantities are chosen so every expected percentage is exact or far from a
# rounding boundary. The stub answers every query; nothing contacts a cluster.
if ! python3 - "$scratch" <<'PY'
import json, pathlib, sys
root=pathlib.Path(sys.argv[1])
def save(name, items):
    (root/(name+'.json')).write_text(json.dumps({'items':items}))
def node(name='node-a', cpu='4', memory='8Gi', pods='110', ready=True, unschedulable=False, taints=None):
    spec={}
    if unschedulable:
        spec['unschedulable']=True
    if taints:
        spec['taints']=taints
    return {'metadata':{'name':name},'spec':spec,
            'status':{'allocatable':{'cpu':cpu,'memory':memory,'pods':pods},
                      'conditions':[{'type':'Ready','status':'True' if ready else 'False'}]}}
def ctr(name='app', cpu=None, memory=None, **extra):
    req={}
    if cpu is not None:
        req['cpu']=cpu
    if memory is not None:
        req['memory']=memory
    doc={'name':name,'resources':{'requests':req} if req else {}}
    doc.update(extra)
    return doc
count=[0]
def pod(containers, node='node-a', phase='Running', init=None, overhead=None, conditions=None):
    count[0]+=1
    spec={'containers':containers}
    if node:
        spec['nodeName']=node
    if init:
        spec['initContainers']=init
    if overhead:
        spec['overhead']=overhead
    status={'phase':phase}
    if conditions:
        status['conditions']=conditions
    return {'metadata':{'namespace':'demo','name':'pod-%d' % count[0]},'spec':spec,'status':status}
# Nodes: node-a is 4 cores / 8Gi / 110 pods; quant is 1000m / 1000M so each
# quantity form lands on a distinct, exact percentage.
save('nodes-one', [node()])
save('nodes-quant', [node('quant',cpu='1000m',memory='1000M')])
save('nodes-pods-small', [node(pods='5')])
save('nodes-notready', [node(),node('node-b',ready=False)])
save('nodes-cordoned-tainted', [node(unschedulable=True,taints=[{'key':'node.kubernetes.io/unschedulable','effect':'NoSchedule'},
                                                                {'key':'dedicated','value':'batch','effect':'NoSchedule'}])])
save('nodes-bad-quantity', [node(cpu='12x')])
save('nodes-no-alloc', [{'metadata':{'name':'bare'},'status':{'conditions':[{'type':'Ready','status':'True'}]}}])
save('pods-quiet', [pod([ctr(cpu='500m',memory='1Gi')])])
save('pods-cpu-hot', [pod([ctr(cpu='1700m',memory='1Gi')]),pod([ctr(cpu='1.7',memory='1Gi')])])
save('pods-mem-hot', [pod([ctr(cpu='100m',memory='7Gi')])])
save('pods-five', [pod([ctr(cpu='100m',memory='128Mi')]) for _ in range(5)])
for label,cpu,mem in (('cpu-half','0.5',None),('cpu-milli','250m',None),('cpu-cores','2',None),
                      ('mem-mega','500M',None),('mem-exp','129e6',None),('mem-plain','128974848',None),
                      ('mem-mebi','250Mi',None),('mem-gibi-frac','0.5Gi',None),('mem-giga','1G',None),
                      ('mem-kilo','500000k',None),('mem-milli','262144000000m',None)):
    if label.startswith('cpu'):
        save('q-'+label, [pod([ctr(cpu=cpu)],node='quant')])
    else:
        save('q-'+label, [pod([ctr(memory=cpu)],node='quant')])
save('q-init-max', [pod([ctr('a','100m'),ctr('b','100m')],node='quant',init=[ctr('migrate','500m')])])
save('q-sidecar-sum', [pod([ctr('app','200m')],node='quant',
                           init=[ctr('setup','250m'),ctr('proxy','100m',restartPolicy='Always')])])
save('q-overhead', [pod([ctr('app','250m')],node='quant',overhead={'cpu':'250m'})])
save('q-succeeded-ignored', [pod([ctr(cpu='900m')],node='quant',phase='Succeeded'),
                             pod([ctr(cpu='900m')],node='quant',phase='Failed'),
                             pod([ctr(cpu='100m')],node='quant')])
save('q-unscheduled-ignored', [pod([ctr(cpu='900m')],node=None,phase='Pending'),pod([ctr(cpu='100m')],node='quant')])
save('pods-no-requests', [pod([ctr()]),pod([ctr()]),pod([ctr(cpu='100m')])])
save('pods-pending', [pod([ctr(cpu='100m')]),
                      pod([ctr(cpu='64')],node=None,phase='Pending',conditions=[{'type':'PodScheduled','status':'False','reason':'Unschedulable',
                          'message':'0/3 nodes are available: 3 Insufficient cpu.'}])])
save('pods-bad-quantity', [pod([ctr(cpu='12x')])])
save('pods-empty', [])
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
printf '%s\n' "$*" >> "$CAP_CALLS"
case " $* " in
  *" cluster-info "*) exit 0 ;;
  *" get nodes "*) resource=nodes; fixture="$CAP_NODES" ;;
  *" get pods "*) resource=pods; fixture="$CAP_PODS" ;;
  *) printf 'unexpected stub command: %s\n' "$*" >&2; exit 99 ;;
esac
if [[ "$resource" == "$CAP_FAIL_RESOURCE" ]]; then exit 1; fi
if [[ "$resource" == "$CAP_EMPTY_RESOURCE" ]]; then exit 0; fi
if [[ "$resource" == "$CAP_BAD_RESOURCE" ]]; then fixture="$CAP_BAD_FIXTURE"; fi
cat "$CAP_FIXTURE_DIR/$fixture.json"
KUBECTL
chmod +x "$scratch/kubectl" || { err 'could not make kubectl stub executable'; exit 1; }

TIMEOUT_BIN="$(command -v timeout || true)"
run_cap() {
  : > "$CAP_CALLS"
  if [[ -n "$TIMEOUT_BIN" ]]; then
    out="$(PATH="$scratch:$PATH" "$TIMEOUT_BIN" 20 "$SCRIPT" "$@" 2>&1)"; rc=$?
  else
    out="$(PATH="$scratch:$PATH" "$SCRIPT" "$@" 2>&1)"; rc=$?
  fi
  cat "$CAP_CALLS" >> "$ALL_CALLS"
}
reset_fixtures() {
  export CAP_NODES=nodes-one CAP_PODS=pods-quiet
  export CAP_FAIL_RESOURCE='' CAP_EMPTY_RESOURCE='' CAP_BAD_RESOURCE='' CAP_BAD_FIXTURE=malformed
}

printf '\n--- Thresholds ---\n'
reset_fixtures
run_cap
assert_rc 'a lightly loaded node -> quiet exit 4' 4 "$rc"
assert_contains 'the table names the node' 'node-a  500m/4000m 13%'
assert_contains 'memory is set against allocatable' '1.0Gi/8.0Gi 13%'
assert_contains 'quiet summary' 'capacity looks quiet (no node at or above 85%, nothing pending)'
assert_contains 'cluster totals are printed' 'cluster   schedulable Ready nodes: cpu 500m/4000m 13%'
calls="$(cat "$CAP_CALLS")"
if [[ "$calls" == *'get nodes -o json'* && "$calls" == *'get pods --all-namespaces -o json'* ]]; then
  ok 'one nodes query and one all-namespaces pods query'
else
  err "unexpected queries: $calls"
fi

for case_ in \
  'nodes-one|pods-cpu-hot|node node-a: cpu 85% requested (threshold 85%)' \
  'nodes-one|pods-mem-hot|node node-a: memory 88% requested (threshold 85%)' \
  'nodes-pods-small|pods-five|node node-a: pods 100% requested (threshold 85%)' \
  'nodes-notready|pods-quiet|node node-b: NotReady'
do
  IFS='|' read -r nodes pods want <<<"$case_"
  reset_fixtures
  export CAP_NODES="$nodes" CAP_PODS="$pods"
  run_cap
  assert_rc "$nodes/$pods -> findings exit 0" 0 "$rc"
  assert_contains "$nodes/$pods finding" "$want"
  assert_absent "$nodes/$pods is not quiet" 'capacity looks quiet'
done
reset_fixtures
export CAP_PODS=pods-cpu-hot
run_cap --threshold 90
assert_rc '--threshold 90 leaves an 85% node alone' 4 "$rc"
run_cap --threshold=85 --context fixture-context
assert_rc '--threshold=85 reports it again' 0 "$rc"
if [[ "$(cat "$CAP_CALLS")" == *'--context fixture-context get nodes -o json'* ]]; then
  ok '--context reaches every query'
else
  err "--context not passed through: $(cat "$CAP_CALLS")"
fi
reset_fixtures
run_cap --threshold 100
assert_rc '--threshold 100 is accepted' 4 "$rc"

reset_fixtures
export CAP_NODES=nodes-cordoned-tainted
run_cap
assert_rc 'cordoned and tainted nodes are flags, not findings' 4 "$rc"
assert_contains 'flags are shown' 'cordoned,dedicated:NoSchedule'
assert_contains 'no schedulable node is said plainly' 'cluster   no schedulable Ready node to add up'

printf '\n--- Every quantity form, through the percentage it produces ---\n'
# The sidecar case is the one a simpler formula gets wrong: an ordinary init
# container (250m) runs before the sidecar starts, so the pod needs the app
# plus the sidecar (300m), not init plus sidecar (350m).
for case_ in \
  'q-cpu-half|500m/1000m 50%' \
  'q-cpu-milli|250m/1000m 25%' \
  'q-cpu-cores|2000m/1000m 200%' \
  'q-mem-mega|477Mi/954Mi 50%' \
  'q-mem-exp|123Mi/954Mi 13%' \
  'q-mem-plain|123Mi/954Mi 13%' \
  'q-mem-mebi|250Mi/954Mi 26%' \
  'q-mem-gibi-frac|512Mi/954Mi 54%' \
  'q-mem-giga|954Mi/954Mi 100%' \
  'q-mem-kilo|477Mi/954Mi 50%' \
  'q-mem-milli|250Mi/954Mi 26%' \
  'q-init-max|500m/1000m 50%' \
  'q-sidecar-sum|300m/1000m 30%' \
  'q-overhead|500m/1000m 50%' \
  'q-succeeded-ignored|100m/1000m 10%' \
  'q-unscheduled-ignored|100m/1000m 10%'
do
  IFS='|' read -r fixture want <<<"$case_"
  reset_fixtures
  export CAP_NODES=nodes-quant CAP_PODS="$fixture"
  run_cap
  assert_contains "$fixture" "$want"
done
reset_fixtures
export CAP_NODES=nodes-quant CAP_PODS=q-unscheduled-ignored
run_cap
assert_absent 'a pod with no node and no Unschedulable condition is not pending' 'pending demo/'

printf '\n--- Requests that are missing, pending pods, bad quantities ---\n'
reset_fixtures
export CAP_PODS=pods-no-requests
run_cap
assert_contains 'pods without requests are counted' 'requests  2 scheduled pod(s) declare no cpu or memory request'
assert_rc 'missing requests alone are not a finding' 4 "$rc"
reset_fixtures
export CAP_PODS=pods-pending
run_cap
assert_rc 'an Unschedulable pod -> findings exit 0' 0 "$rc"
assert_contains 'pending pod is listed with the scheduler message' ': 0/3 nodes are available: 3 Insufficient cpu.'
assert_contains 'pending pods have their own heading' '== Pending =='
for case_ in 'CAP_NODES|nodes-bad-quantity' 'CAP_PODS|pods-bad-quantity'; do
  IFS='|' read -r var fixture <<<"$case_"
  reset_fixtures
  export "$var=$fixture"
  run_cap
  assert_rc "$fixture -> incomplete exit 1" 1 "$rc"
  assert_contains "$fixture is named" 'could not parse node or pod quantities'
done
reset_fixtures
export CAP_NODES=nodes-no-alloc
run_cap
assert_rc 'a node without allocatable is unknown, not an error' 4 "$rc"
assert_contains 'unknown allocatable is shown as such' 'bare  0m/? ?%'

printf '\n--- Failed queries and malformed JSON ---\n'
for resource in nodes pods; do
  for mode in query empty malformed missing-items invalid-items invalid-entry; do
    reset_fixtures
    case "$mode" in
      query) export CAP_FAIL_RESOURCE="$resource" ;;
      empty) export CAP_EMPTY_RESOURCE="$resource" ;;
      *) export CAP_BAD_RESOURCE="$resource" CAP_BAD_FIXTURE="$mode" ;;
    esac
    run_cap
    assert_rc "$resource $mode -> incomplete exit 1" 1 "$rc"
    assert_contains "$resource $mode reported" 'could not'
    assert_contains "$resource $mode incomplete summary" 'capacity check incomplete'
    assert_absent "$resource $mode cannot claim quiet" 'capacity looks quiet'
    calls="$(cat "$CAP_CALLS")"
    if [[ "$calls" == *'get nodes'* && "$calls" == *'get pods'* ]]; then
      ok "$resource $mode still ran both queries"
    else
      err "$resource $mode stopped early: $calls"
    fi
  done
done

printf '\n--- Usage, environment and read-only ---\n'
for pct in 0 101 abc -5 85.5; do
  run_cap --threshold "$pct"
  assert_rc "--threshold $pct -> 3" 3 "$rc"
done
bare_path="$(mktemp -d)"
ln -s "$BASH" "$bare_path/bash"
if [[ -n "$TIMEOUT_BIN" ]]; then
  out="$(PATH="$bare_path" "$TIMEOUT_BIN" 20 "$SCRIPT" 2>&1)"; rc=$?
else
  out="$(PATH="$bare_path" "$SCRIPT" 2>&1)"; rc=$?
fi
assert_rc 'missing kubectl -> exit 2' 2 "$rc"
rm -rf "$bare_path"
if [[ ! -s "$ALL_CALLS" ]]; then
  err 'no kubectl call was recorded; the read-only check would pass vacuously'
elif grep -Evq '^(--context [^ ]+ )?(get|cluster-info)( |$)' "$ALL_CALLS"; then
  err "a kubectl verb other than get/cluster-info ran: $(grep -Ev '^(--context [^ ]+ )?(get|cluster-info)( |$)' "$ALL_CALLS" | head -3)"
else
  ok 'only get and cluster-info were ever executed'
fi

printf '\nNode capacity failures: %s\n' "$failures"
(( failures == 0 ))
