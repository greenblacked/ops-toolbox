#!/usr/bin/env bash
# Exercise the node drain preflight with secret-free kubectl fixtures.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../kubectl_drain_preflight.sh"
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
export DRAIN_FIXTURE_DIR="$scratch"
DRAIN_CALLS="$scratch/calls"
ALL_CALLS="$scratch/all-calls"
: > "$ALL_CALLS"
export DRAIN_CALLS

# Nodes, pods and budgets shaped as the API returns them. The stub answers
# every query; nothing contacts a cluster.
if ! python3 - "$scratch" <<'PY'
import json, pathlib, sys
root=pathlib.Path(sys.argv[1])
def save(name, doc):
    (root/(name+'.json')).write_text(json.dumps(doc))
def node(name='node-a', ready=True, unschedulable=False, taints=None, disk=None):
    spec={}
    if unschedulable:
        spec['unschedulable']=True
    if taints:
        spec['taints']=taints
    labels={'kubernetes.io/hostname':name}
    if disk:
        labels['disk']=disk
    return {'metadata':{'name':name,'labels':labels},'spec':spec,
            'status':{'conditions':[{'type':'Ready','status':'True' if ready else 'False',
                                     'reason':'KubeletReady' if ready else 'KubeletNotReady'}]}}
def pod(name, owner='ReplicaSet', labels=None, volumes=None, phase='Running', ns='demo', annotations=None, ready=None, spec_extra=None):
    meta={'namespace':ns,'name':name,'labels':labels or {'app':'web'}}
    if owner:
        meta['ownerReferences']=[{'kind':owner,'name':name.rsplit('-',1)[0],'controller':True}]
    if annotations:
        meta['annotations']=annotations
    status={'phase':phase}
    if ready is not None:
        status['conditions']=[{'type':'Ready','status':'True' if ready else 'False'}]
    spec={'nodeName':'node-a','volumes':volumes or []}
    spec.update(spec_extra or {})
    return {'metadata':meta,'spec':spec,'status':status}
def affinity(*values):
    return {'affinity':{'nodeAffinity':{'requiredDuringSchedulingIgnoredDuringExecution':{'nodeSelectorTerms':[
        {'matchExpressions':[{'key':'kubernetes.io/hostname','operator':'In','values':list(values)}]}]}}}}
def pvc(name, volume, ns='demo'):
    return {'metadata':{'namespace':ns,'name':name},'spec':{'volumeName':volume}}
def pv(name, *hosts):
    spec={}
    if hosts:
        spec['nodeAffinity']={'required':{'nodeSelectorTerms':[
            {'matchExpressions':[{'key':'kubernetes.io/hostname','operator':'In','values':list(hosts)}]}]}}
    return {'metadata':{'name':name},'spec':spec}
data_volume=[{'name':'data','persistentVolumeClaim':{'claimName':'web-data'}}]
def pdb(name, allowed, selector, ns='demo', policy=None):
    spec={'selector':selector,'minAvailable':1}
    if policy:
        spec['unhealthyPodEvictionPolicy']=policy
    return {'metadata':{'namespace':ns,'name':name},'spec':spec,
            'status':{'disruptionsAllowed':allowed}}
items=lambda *docs: {'items':list(docs)}
save('node-ready', node())
save('node-cordoned', node(unschedulable=True,taints=[{'key':'node.kubernetes.io/unschedulable','effect':'NoSchedule'}]))
save('node-notready', node(ready=False))
save('pods-empty', items())
save('pods-clean', items(pod('web-7d9f8-abcde'),pod('web-7d9f8-fghij')))
save('pods-daemonset-only', items(pod('agent-x1',owner='DaemonSet',labels={'app':'agent'},volumes=[{'name':'buf','emptyDir':{}}])))
save('pods-bare', items(pod('scratch',owner=None,labels={'run':'scratch'})))
save('pods-emptydir', items(pod('web-7d9f8-abcde',volumes=[{'name':'cache','emptyDir':{}}])))
save('pods-pvc', items(pod('web-7d9f8-abcde',volumes=[{'name':'data','persistentVolumeClaim':{'claimName':'web-data'}}])))
save('pods-statefulset', items(pod('db-0',owner='StatefulSet',labels={'app':'db'})))
save('pods-mirror', items(pod('kube-proxy-node-a',owner='Node',labels={'component':'kube-proxy'},
                              annotations={'kubernetes.io/config.mirror':'abc123'})))
save('pods-terminal', items(pod('report-1',owner=None,phase='Succeeded'),pod('report-2',owner='Job',phase='Failed')))
save('pods-unready', items(pod('web-7d9f8-abcde',ready=False),pod('web-7d9f8-fghij',ready=True)))
save('pods-pending', items(pod('web-7d9f8-abcde',phase='Pending'),pod('web-7d9f8-fghij',ready=False)))
save('pods-pending-multi', items(pod('web-7d9f8-abcde',phase='Pending')))
save('pdb-zero-alwaysallow', items(pdb('web',0,{'matchLabels':{'app':'web'}},policy='AlwaysAllow')))
save('pdb-zero-ifhealthy', items(pdb('web',0,{'matchLabels':{'app':'web'}},policy='IfHealthyBudget')))
save('pdb-two-zero', items(pdb('web',0,{'matchLabels':{'app':'web'}}),pdb('web-2',0,{'matchLabels':{'app':'web'}})))
save('pdb-none', items())
save('pdb-allows-one', items(pdb('web',1,{'matchLabels':{'app':'web'}})))
save('pdb-zero', items(pdb('web',0,{'matchLabels':{'app':'web'}})))
save('pdb-zero-expr', items(pdb('web',0,{'matchExpressions':[{'key':'app','operator':'In','values':['web','api']}]})))
save('pdb-zero-notin', items(pdb('web',0,{'matchExpressions':[{'key':'app','operator':'NotIn','values':['web']}]})))
save('pdb-empty-selector', items(pdb('everything',0,{})))
save('pdb-other-namespace', items(pdb('web',0,{'matchLabels':{'app':'web'}},ns='other')))
save('pdb-two-match', items(pdb('web',1,{'matchLabels':{'app':'web'}}),pdb('web-also',1,{'matchExpressions':[{'key':'app','operator':'Exists'}]})))
save('pods-selector-host', items(pod('web-7d9f8-abcde',spec_extra={'nodeSelector':{'kubernetes.io/hostname':'node-a'}})))
save('pods-selector-label', items(pod('web-7d9f8-abcde',spec_extra={'nodeSelector':{'disk':'nvme'}})))
save('pods-selector-movable', items(pod('web-7d9f8-abcde',spec_extra={'nodeSelector':{'disk':'ssd'}})))
save('pods-affinity-pinned', items(pod('web-7d9f8-abcde',spec_extra=affinity('node-a'))))
save('pods-affinity-movable', items(pod('web-7d9f8-abcde',spec_extra=affinity('node-a','node-b'))))
save('pods-pvc-local', items(pod('web-7d9f8-abcde',volumes=data_volume)))
save('pvc-none', items())
save('pvc-local', items(pvc('web-data','pv-local')))
save('pv-none', items())
save('pv-local', items(pv('pv-local','node-a')))
save('pv-movable', items(pv('pv-local','node-a','node-b')))
save('pv-unpinned', items(pv('pv-local')))
save('nodes-others-ready', items(node(disk='nvme'),node('node-b',disk='ssd'),node('node-c',unschedulable=True,disk='nvme')))
save('nodes-only-self', items(node(),node('node-b',ready=False),node('node-c',unschedulable=True)))
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
printf '%s\n' "$*" >> "$DRAIN_CALLS"
case " $* " in
  *" cluster-info "*) exit 0 ;;
  *" get node node-a "*) resource=node; fixture="$DRAIN_NODE" ;;
  *" get pods "*)
    if [[ " $* " != *" --field-selector spec.nodeName=node-a "* ]]; then
      printf 'pods query is not scoped to the node: %s\n' "$*" >&2
      exit 98
    fi
    resource=pods; fixture="$DRAIN_PODS" ;;
  *" get pdb "*) resource=pdb; fixture="$DRAIN_PDB" ;;
  *" get nodes "*) resource=nodes; fixture="$DRAIN_NODES" ;;
  *" get pvc "*) resource=pvc; fixture="$DRAIN_PVC" ;;
  *" get pv "*) resource=pv; fixture="$DRAIN_PV" ;;
  *) printf 'unexpected stub command: %s\n' "$*" >&2; exit 99 ;;
esac
if [[ "$resource" == "$DRAIN_FAIL_RESOURCE" ]]; then exit 1; fi
if [[ "$resource" == "$DRAIN_EMPTY_RESOURCE" ]]; then exit 0; fi
if [[ "$resource" == "$DRAIN_BAD_RESOURCE" ]]; then fixture="$DRAIN_BAD_FIXTURE"; fi
cat "$DRAIN_FIXTURE_DIR/$fixture.json"
KUBECTL
chmod +x "$scratch/kubectl" || { err 'could not make kubectl stub executable'; exit 1; }

TIMEOUT_BIN="$(command -v timeout || true)"
run_drain() {
  : > "$DRAIN_CALLS"
  if [[ -n "$TIMEOUT_BIN" ]]; then
    out="$(PATH="$scratch:$PATH" "$TIMEOUT_BIN" 20 "$SCRIPT" "$@" 2>&1)"; rc=$?
  else
    out="$(PATH="$scratch:$PATH" "$SCRIPT" "$@" 2>&1)"; rc=$?
  fi
  cat "$DRAIN_CALLS" >> "$ALL_CALLS"
}
reset_fixtures() {
  export DRAIN_NODE=node-ready DRAIN_PODS=pods-clean DRAIN_PDB=pdb-allows-one DRAIN_NODES=nodes-others-ready DRAIN_PVC=pvc-none DRAIN_PV=pv-none
  export DRAIN_FAIL_RESOURCE='' DRAIN_EMPTY_RESOURCE='' DRAIN_BAD_RESOURCE='' DRAIN_BAD_FIXTURE=malformed
}

printf '\n--- A node with nothing in the way ---\n'
reset_fixtures
run_drain --node node-a
assert_rc 'replicated pods with room to move -> nothing to report exit 4' 4 "$rc"
assert_contains 'verdict names the absence of blockers and the limit' 'no blockers found and nothing to note (placement of evicted pods is not simulated: taints, affinity, resources, topology)'
assert_absent 'the verdict never says safe' 'safe to drain'
assert_contains 'cordon command is printed' 'next      kubectl cordon node-a'
assert_contains 'drain command carries only the default flags' 'next      kubectl drain node-a --ignore-daemonsets --timeout=300s'
assert_contains 'pods are counted' 'pods      2 to evict'
assert_absent 'nothing to block' 'BLOCKER'
calls="$(cat "$DRAIN_CALLS")"
for query in 'get node node-a -o json' 'get pods --all-namespaces --field-selector spec.nodeName=node-a -o json' \
             'get pdb --all-namespaces -o json' 'get nodes -o json' \
             'get pvc --all-namespaces -o json' 'get pv -o json'; do
  if [[ "$calls" == *"$query"* ]]; then ok "queried: $query"; else err "missing query '$query': $calls"; fi
done

for case_ in \
  'DRAIN_PDB|pdb-other-namespace|a zero budget in another namespace does not apply' \
  'DRAIN_PDB|pdb-zero-notin|a NotIn selector that excludes the pods does not apply' \
  'DRAIN_PODS|pods-daemonset-only|DaemonSet pods are skipped by --ignore-daemonsets' \
  'DRAIN_PODS|pods-mirror|static mirror pods are left alone' \
  'DRAIN_PODS|pods-terminal|finished pods are ignored' \
  'DRAIN_PODS|pods-selector-movable|a nodeSelector another node satisfies can move' \
  'DRAIN_PODS|pods-affinity-movable|a required affinity another node satisfies can move'
do
  IFS='|' read -r var fixture label <<<"$case_"
  reset_fixtures
  export "$var=$fixture"
  run_drain --node node-a
  assert_rc "$label -> exit 4" 4 "$rc"
  assert_absent "$fixture gives no blocker" 'BLOCKER'
done
reset_fixtures
export DRAIN_PODS=pods-mirror DRAIN_NODES=nodes-only-self
run_drain --node node-a
assert_rc 'nothing to evict needs no other node' 4 "$rc"

reset_fixtures
export DRAIN_NODE=node-cordoned
run_drain --node=node-a
assert_rc 'an already cordoned node can still be safe' 4 "$rc"
assert_contains 'cordon is noted' 'cordoned  already (spec.unschedulable)'
assert_contains 'taints are listed' 'taints    node.kubernetes.io/unschedulable:NoSchedule'
reset_fixtures
export DRAIN_NODE=node-notready
run_drain --node node-a
assert_contains 'NotReady node is described' 'ready     NotReady (KubeletNotReady)'

printf '\n--- Blockers ---\n'
for case_ in \
  'DRAIN_PDB|pdb-zero|BLOCKER   pod demo/web-7d9f8-abcde: drain will wait forever: PDB demo/web allows 0 disruptions' \
  'DRAIN_PDB|pdb-zero-expr|BLOCKER   pod demo/web-7d9f8-fghij: drain will wait forever: PDB demo/web allows 0 disruptions' \
  'DRAIN_PDB|pdb-empty-selector|BLOCKER   pod demo/web-7d9f8-abcde: drain will wait forever: PDB demo/everything allows 0 disruptions' \
  'DRAIN_PDB|pdb-two-match|BLOCKER   pod demo/web-7d9f8-abcde matches 2 PodDisruptionBudgets' \
  'DRAIN_PODS|pods-bare|BLOCKER   pod demo/scratch has no controller: kubectl drain refuses it without --force' \
  'DRAIN_NODES|nodes-only-self|BLOCKER   no other node is Ready and schedulable: 2 evicted pod(s) cannot reschedule anywhere'
do
  IFS='|' read -r var fixture want <<<"$case_"
  reset_fixtures
  export "$var=$fixture"
  run_drain --node node-a
  assert_rc "$fixture -> findings exit 0" 0 "$rc"
  assert_contains "$fixture blocker" "$want"
  assert_contains "$fixture asks for the blockers to be resolved" 'blocker(s): resolve them before draining'
  assert_absent "$fixture gets no clean verdict" 'placement of evicted pods is not simulated'
done
for case_ in \
  'DRAIN_PODS|pods-selector-host|pvc-none|pv-none|BLOCKER   pod demo/web-7d9f8-abcde cannot move: its nodeSelector or required nodeAffinity matches no other Ready schedulable node' \
  'DRAIN_PODS|pods-selector-label|pvc-none|pv-none|BLOCKER   pod demo/web-7d9f8-abcde cannot move: its nodeSelector or required nodeAffinity matches no other Ready schedulable node' \
  'DRAIN_PODS|pods-affinity-pinned|pvc-none|pv-none|BLOCKER   pod demo/web-7d9f8-abcde cannot move: its nodeSelector or required nodeAffinity matches no other Ready schedulable node' \
  'DRAIN_PODS|pods-pvc-local|pvc-local|pv-local|BLOCKER   pod demo/web-7d9f8-abcde cannot move: PVC web-data is bound to PV pv-local, whose nodeAffinity matches no other Ready schedulable node'
do
  IFS='|' read -r var fixture pvc_fixture pv_fixture want <<<"$case_"
  reset_fixtures
  export "$var=$fixture"
  export DRAIN_PVC="$pvc_fixture" DRAIN_PV="$pv_fixture"
  run_drain --node node-a
  assert_rc "$fixture -> findings exit 0" 0 "$rc"
  assert_contains "$fixture blocker" "$want"
  assert_absent "$fixture gets no clean verdict" 'placement of evicted pods is not simulated'
done
for pv_fixture in pv-movable pv-unpinned; do
  reset_fixtures
  export DRAIN_PODS=pods-pvc-local DRAIN_PVC=pvc-local DRAIN_PV="$pv_fixture"
  run_drain --node node-a
  assert_absent "a volume that $pv_fixture allows elsewhere does not block" 'BLOCKER'
  assert_contains "$pv_fixture still gets the PVC note" 'NOTE      pod demo/web-7d9f8-abcde mounts PVC web-data'
  assert_contains "$pv_fixture verdict carries the placement caveat" 'placement of evicted pods is not simulated'
done
reset_fixtures
export DRAIN_PODS=pods-unready DRAIN_PDB=pdb-zero-alwaysallow
run_drain --node node-a
assert_contains 'AlwaysAllow still blocks the Ready pod' 'BLOCKER   pod demo/web-7d9f8-fghij: drain will wait forever: PDB demo/web allows 0 disruptions'
assert_absent 'AlwaysAllow lets the not-Ready pod go' 'BLOCKER   pod demo/web-7d9f8-abcde'
reset_fixtures
export DRAIN_PODS=pods-pending DRAIN_PDB=pdb-zero
run_drain --node node-a
assert_absent 'a Pending pod never waits on a budget' 'BLOCKER   pod demo/web-7d9f8-abcde'
assert_contains 'a Running not-Ready pod still waits on a zero budget' 'BLOCKER   pod demo/web-7d9f8-fghij: drain will wait forever: PDB demo/web allows 0 disruptions'
reset_fixtures
export DRAIN_PODS=pods-pending-multi DRAIN_PDB=pdb-two-zero
run_drain --node node-a
assert_absent 'a Pending pod is not refused for matching two budgets' 'BLOCKER'
reset_fixtures
export DRAIN_PODS=pods-unready DRAIN_PDB=pdb-zero-ifhealthy
run_drain --node node-a
assert_contains 'IfHealthyBudget still blocks the not-Ready pod' 'BLOCKER   pod demo/web-7d9f8-abcde: drain will wait forever: PDB demo/web allows 0 disruptions'
reset_fixtures
export DRAIN_PODS=pods-unready DRAIN_PDB=pdb-zero
run_drain --node node-a
assert_contains 'no policy (default) still blocks the not-Ready pod' 'BLOCKER   pod demo/web-7d9f8-abcde: drain will wait forever: PDB demo/web allows 0 disruptions'
reset_fixtures
export DRAIN_PODS=pods-bare
run_drain --node node-a
assert_contains 'a bare pod puts --force in the printed drain' 'next      kubectl drain node-a --ignore-daemonsets --force --timeout=300s'
assert_contains '--force comes with its warning' '--force deletes the pods with no controller above'

printf '\n--- Notes ---\n'
for case_ in \
  'pods-emptydir|NOTE      pod demo/web-7d9f8-abcde uses emptyDir cache: its data is lost; drain needs --delete-emptydir-data' \
  'pods-pvc|NOTE      pod demo/web-7d9f8-abcde mounts PVC web-data' \
  'pods-statefulset|NOTE      pod demo/db-0 belongs to StatefulSet db'
do
  IFS='|' read -r fixture want <<<"$case_"
  reset_fixtures
  export DRAIN_PODS="$fixture"
  run_drain --node node-a
  assert_rc "$fixture -> findings exit 0" 0 "$rc"
  assert_contains "$fixture note" "$want"
  assert_absent "$fixture is not a blocker" 'BLOCKER'
done
reset_fixtures
export DRAIN_PODS=pods-emptydir
run_drain --node node-a
assert_contains 'emptyDir adds only --delete-emptydir-data' 'next      kubectl drain node-a --ignore-daemonsets --delete-emptydir-data --timeout=300s'

printf '\n--- Failed queries and malformed JSON never give a verdict ---\n'
for resource in node pods pdb nodes pvc pv; do
  for mode in query empty malformed missing-items invalid-items invalid-entry; do
    reset_fixtures
    case "$mode" in
      query) export DRAIN_FAIL_RESOURCE="$resource" ;;
      empty) export DRAIN_EMPTY_RESOURCE="$resource" ;;
      *) export DRAIN_BAD_RESOURCE="$resource" DRAIN_BAD_FIXTURE="$mode" ;;
    esac
    run_drain --node node-a
    assert_rc "$resource $mode -> incomplete exit 1" 1 "$rc"
    assert_contains "$resource $mode reported" 'could not'
    assert_contains "$resource $mode says there is no verdict" 'drain preflight incomplete, no verdict'
    assert_absent "$resource $mode never gives a clean verdict" 'placement of evicted pods is not simulated'
    assert_absent "$resource $mode never says no blockers found" 'no blockers found'
    assert_absent "$resource $mode prints no drain command" 'kubectl drain node-a'
    if [[ "$(cat "$DRAIN_CALLS")" == *'get nodes -o json'* ]]; then
      ok "$resource $mode still ran every query"
    else
      err "$resource $mode stopped early: $(cat "$DRAIN_CALLS")"
    fi
  done
done

printf '\n--- Usage, environment and read-only ---\n'
run_drain
assert_rc 'missing --node -> 3' 3 "$rc"
assert_contains 'missing --node is named' '--node is required'
if [[ ! -s "$DRAIN_CALLS" ]]; then ok 'a usage error never reaches kubectl'; else err "usage error called kubectl: $(cat "$DRAIN_CALLS")"; fi
bare_path="$(mktemp -d)"
ln -s "$BASH" "$bare_path/bash"
if [[ -n "$TIMEOUT_BIN" ]]; then
  out="$(PATH="$bare_path" "$TIMEOUT_BIN" 20 "$SCRIPT" --node node-a 2>&1)"; rc=$?
else
  out="$(PATH="$bare_path" "$SCRIPT" --node node-a 2>&1)"; rc=$?
fi
assert_rc 'missing kubectl -> exit 2' 2 "$rc"
rm -rf "$bare_path"

# The output legitimately prints "kubectl drain"; the call log is what proves
# nothing but reads ever ran.
if [[ ! -s "$ALL_CALLS" ]]; then
  err 'no kubectl call was recorded; the read-only check would pass vacuously'
elif grep -Eq '(cordon|uncordon|drain|delete|patch|evict|taint|label|annotate)' "$ALL_CALLS"; then
  err "a mutating kubectl command ran: $(grep -E '(cordon|uncordon|drain|delete|patch|evict|taint|label|annotate)' "$ALL_CALLS" | head -3)"
elif grep -Evq '^(--context [^ ]+ )?(get|cluster-info)( |$)' "$ALL_CALLS"; then
  err "a kubectl verb other than get/cluster-info ran: $(grep -Ev '^(--context [^ ]+ )?(get|cluster-info)( |$)' "$ALL_CALLS" | head -3)"
else
  ok 'only get and cluster-info were ever executed'
fi

printf '\nDrain preflight failures: %s\n' "$failures"
(( failures == 0 ))
