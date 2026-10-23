#!/usr/bin/env bash
# Exercise the workload template audit with secret-free kubectl fixtures.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../kubectl_workload_audit.sh"
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
export AUD_FIXTURE_DIR="$scratch"
AUD_CALLS="$scratch/calls"
ALL_CALLS="$scratch/all-calls"
: > "$ALL_CALLS"
export AUD_CALLS

# Pod templates shaped as the API returns them. The stub answers every query;
# nothing contacts a cluster.
if ! python3 - "$scratch" <<'PY'
import copy, json, pathlib, sys
root=pathlib.Path(sys.argv[1])
def save(name, items):
    (root/(name+'.json')).write_text(json.dumps({'items':items}))
def ctr(name='web', image='registry.example/web:1.4.2', resources='full', probe=True, sc='restricted'):
    doc={'name':name,'image':image}
    if resources == 'full':
        doc['resources']={'requests':{'cpu':'100m','memory':'128Mi'},'limits':{'memory':'256Mi'}}
    elif resources == 'no-limit':
        doc['resources']={'requests':{'cpu':'100m','memory':'128Mi'}}
    elif resources == 'limits-only':
        doc['resources']={'limits':{'cpu':'200m','memory':'256Mi'}}
    if probe:
        doc['readinessProbe']={'httpGet':{'path':'/healthz','port':8080}}
    if sc == 'restricted':
        doc['securityContext']={'allowPrivilegeEscalation':False,'runAsNonRoot':True}
    elif sc == 'privileged':
        doc['securityContext']={'allowPrivilegeEscalation':False,'runAsNonRoot':True,'privileged':True}
    elif sc == 'no-nonroot':
        doc['securityContext']={'allowPrivilegeEscalation':False}
    return doc
def template(containers, labels=None, **pod):
    spec={'containers':containers}
    spec.update(pod)
    return {'metadata':{'labels':labels or {'app':'web'}},'spec':spec}
def workload(kind='Deployment', name='web', ns='demo', replicas=2, containers=None, **pod):
    tpl=template(containers or [ctr()], **pod)
    spec={'selector':{'matchLabels':{'app':'web'}},'template':tpl}
    if kind != 'DaemonSet':
        spec['replicas']=replicas
    return {'kind':kind,'metadata':{'namespace':ns,'name':name},'spec':spec}
def cronjob(name='report', containers=None):
    tpl=template(containers or [ctr('report',probe=False)])
    return {'kind':'CronJob','metadata':{'namespace':'demo','name':name},
            'spec':{'schedule':'0 * * * *','jobTemplate':{'spec':{'template':tpl}}}}
def pdb(selector, ns='demo', name='web'):
    return {'metadata':{'namespace':ns,'name':name},'spec':{'selector':selector,'minAvailable':1},'status':{'disruptionsAllowed':1}}
save('empty', [])
save('deploy-good', [workload()])
save('pdb-good', [pdb({'matchLabels':{'app':'web'}})])
save('pdb-none', [])
save('pdb-matchexpr', [pdb({'matchExpressions':[{'key':'app','operator':'In','values':['web','api']}]})])
save('no-requests', [workload(containers=[ctr(resources=None)])])
save('no-mem-limit', [workload(containers=[ctr(resources='no-limit')])])
save('limits-only', [workload(containers=[ctr(resources='limits-only')])])
save('no-probe', [workload(containers=[ctr(probe=False)])])
save('sts-no-probe', [workload('StatefulSet','db',containers=[ctr('db',probe=False)])])
save('ds-no-probe', [workload('DaemonSet','agent',containers=[ctr('agent',probe=False)])])
save('cj-latest', [cronjob(containers=[ctr('report','busybox:latest',probe=False)])])
save('cj-good', [cronjob()])
save('image-latest', [workload(containers=[ctr(image='nginx:latest')])])
save('image-notag', [workload(containers=[ctr(image='nginx')])])
save('image-digest', [workload(containers=[ctr(image='nginx@sha256:'+'a'*64)])])
save('image-registry-port', [workload(containers=[ctr(image='registry:5000/app')])])
save('image-registry-port-tagged', [workload(containers=[ctr(image='registry:5000/app:1.2')])])
save('image-init-latest', [workload(containers=[ctr()],initContainers=[ctr('migrate','tools:latest',probe=False)])])
save('privileged', [workload(containers=[ctr(sc='privileged')])])
save('hostnetwork', [workload(hostNetwork=True)])
save('hostpath', [workload(volumes=[{'name':'docker','hostPath':{'path':'/var/run/docker.sock'}}])])
save('runasnonroot-pod-level', [workload(containers=[ctr(sc='no-nonroot')],securityContext={'runAsNonRoot':True})])
save('runasnonroot-missing', [workload(containers=[ctr(sc='no-nonroot')])])
save('escalation-unset', [workload(containers=[ctr(sc=None)],securityContext={'runAsNonRoot':True})])
save('replicas-one', [workload(replicas=1)])
save('replicas-zero', [workload(replicas=0)])
save('kube-system-bad', [workload(ns='kube-system',containers=[ctr(resources=None)]),
                         workload(ns='gke-managed-system',name='agent',containers=[ctr(resources=None)])])
save('many-bad', [workload(name='web-%02d' % i,containers=[ctr(probe=False)]) for i in range(60)])
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
printf '%s\n' "$*" >> "$AUD_CALLS"
case " $* " in
  *" cluster-info "*) exit 0 ;;
  *" get deployments "*) resource=deployments; fixture="$AUD_DEPLOYMENTS" ;;
  *" get statefulsets "*) resource=statefulsets; fixture="$AUD_STATEFULSETS" ;;
  *" get daemonsets "*) resource=daemonsets; fixture="$AUD_DAEMONSETS" ;;
  *" get cronjobs "*) resource=cronjobs; fixture="$AUD_CRONJOBS" ;;
  *" get pdb "*) resource=pdb; fixture="$AUD_PDB" ;;
  *) printf 'unexpected stub command: %s\n' "$*" >&2; exit 99 ;;
esac
if [[ "$resource" == "$AUD_FAIL_RESOURCE" ]]; then exit 1; fi
if [[ "$resource" == "$AUD_EMPTY_RESOURCE" ]]; then exit 0; fi
if [[ "$resource" == "$AUD_BAD_RESOURCE" ]]; then fixture="$AUD_BAD_FIXTURE"; fi
cat "$AUD_FIXTURE_DIR/$fixture.json"
KUBECTL
chmod +x "$scratch/kubectl" || { err 'could not make kubectl stub executable'; exit 1; }

TIMEOUT_BIN="$(command -v timeout || true)"
run_audit() {
  : > "$AUD_CALLS"
  if [[ -n "$TIMEOUT_BIN" ]]; then
    out="$(PATH="$scratch:$PATH" "$TIMEOUT_BIN" 20 "$SCRIPT" "$@" 2>&1)"; rc=$?
  else
    out="$(PATH="$scratch:$PATH" "$SCRIPT" "$@" 2>&1)"; rc=$?
  fi
  cat "$AUD_CALLS" >> "$ALL_CALLS"
}
reset_fixtures() {
  export AUD_DEPLOYMENTS=deploy-good AUD_STATEFULSETS=empty AUD_DAEMONSETS=empty
  export AUD_CRONJOBS=cj-good AUD_PDB=pdb-good
  export AUD_FAIL_RESOURCE='' AUD_EMPTY_RESOURCE='' AUD_BAD_RESOURCE='' AUD_BAD_FIXTURE=malformed
}

printf '\n--- A production-ready workload passes ---\n'
reset_fixtures
run_audit
assert_rc 'requests, limits, probe, pinned tag, restricted context, PDB -> quiet exit 4' 4 "$rc"
assert_contains 'quiet summary' 'workload audit looks quiet'
assert_absent 'no finding is printed' '[warn]'
for resource in deployments statefulsets daemonsets cronjobs pdb; do
  if [[ "$(cat "$AUD_CALLS")" == *"get $resource --all-namespaces -o json"* ]]; then
    ok "default run lists $resource across every namespace"
  else
    err "default run did not list $resource: $(cat "$AUD_CALLS")"
  fi
done

for case_ in \
  'AUD_DEPLOYMENTS|limits-only|a limit alone also sets the request' \
  'AUD_DEPLOYMENTS|image-digest|a digest is pinned' \
  'AUD_DEPLOYMENTS|image-registry-port-tagged|a tag after a registry port is a tag' \
  'AUD_DEPLOYMENTS|runasnonroot-pod-level|runAsNonRoot at pod level covers the container' \
  'AUD_DEPLOYMENTS|replicas-zero|a Deployment scaled to zero is not single-replica' \
  'AUD_DAEMONSETS|ds-no-probe|DaemonSets are exempt from the probe check' \
  'AUD_PDB|pdb-matchexpr|a matchExpressions budget covers the workload' \
  'AUD_DEPLOYMENTS|kube-system-bad|system namespaces are skipped by default'
do
  IFS='|' read -r var fixture label <<<"$case_"
  reset_fixtures
  export "$var=$fixture"
  run_audit
  assert_rc "$label -> exit 4" 4 "$rc"
  assert_absent "$fixture produces no finding" '[warn]'
done

printf '\n--- Each check, its label and its fix ---\n'
for case_ in \
  'AUD_DEPLOYMENTS|no-requests|[risk] deployment demo/web: container web has no cpu request, no memory request, no memory limit|fix       kubectl set resources deployment/web -n demo -c web --requests=cpu=100m,memory=128Mi --limits=memory=256Mi' \
  'AUD_DEPLOYMENTS|no-mem-limit|[risk] deployment demo/web: container web has no memory limit|fix       kubectl set resources deployment/web -n demo -c web' \
  'AUD_DEPLOYMENTS|no-probe|[advice] deployment demo/web: container web has no readinessProbe|fix       add readinessProbe' \
  'AUD_STATEFULSETS|sts-no-probe|[advice] statefulset demo/db: container db has no readinessProbe|fix       add readinessProbe' \
  'AUD_CRONJOBS|cj-latest|[advice] cronjob demo/report: container report runs busybox:latest|fix       kubectl set image cronjob/report -n demo report=REPOSITORY:VERSION' \
  'AUD_DEPLOYMENTS|image-latest|[advice] deployment demo/web: container web runs nginx:latest|fix       kubectl set image deployment/web -n demo web=REPOSITORY:VERSION' \
  'AUD_DEPLOYMENTS|image-notag|[advice] deployment demo/web: container web runs untagged image nginx|fix       kubectl set image deployment/web' \
  'AUD_DEPLOYMENTS|image-registry-port|[advice] deployment demo/web: container web runs untagged image registry:5000/app|fix       kubectl set image deployment/web' \
  'AUD_DEPLOYMENTS|image-init-latest|[advice] deployment demo/web: container migrate runs tools:latest|fix       kubectl set image deployment/web -n demo migrate=' \
  'AUD_DEPLOYMENTS|privileged|[risk] deployment demo/web: container web: privileged|fix       set runAsNonRoot: true' \
  'AUD_DEPLOYMENTS|hostnetwork|[risk] deployment demo/web: pod uses hostNetwork|fix       set runAsNonRoot: true' \
  'AUD_DEPLOYMENTS|hostpath|[risk] deployment demo/web: pod uses hostPath /var/run/docker.sock|fix       set runAsNonRoot: true' \
  'AUD_DEPLOYMENTS|runasnonroot-missing|[advice] deployment demo/web: container web: runAsNonRoot unset|fix       set runAsNonRoot: true' \
  'AUD_DEPLOYMENTS|escalation-unset|[advice] deployment demo/web: container web: allowPrivilegeEscalation not false|fix       set runAsNonRoot: true' \
  'AUD_DEPLOYMENTS|replicas-one|[advice] deployment demo/web: 1 replica, so any restart or node drain is an outage|fix       kubectl scale deployment/web -n demo --replicas=2' \
  'AUD_PDB|pdb-none|[advice] deployment demo/web: 2 replicas and no PodDisruptionBudget|fix       kubectl create poddisruptionbudget web -n demo --selector=app=web --min-available=1 --dry-run=client -o yaml'
do
  IFS='|' read -r var fixture want fix <<<"$case_"
  reset_fixtures
  export "$var=$fixture"
  run_audit
  assert_rc "$fixture -> findings exit 0" 0 "$rc"
  assert_contains "$fixture finding and label" "$want"
  assert_contains "$fixture fix line" "$fix"
  assert_absent "$fixture is not quiet" 'workload audit looks quiet'
done

reset_fixtures
export AUD_DEPLOYMENTS=replicas-one
run_audit --context fixture-context --namespace demo
assert_contains 'a kubectl fix names the context that was read' 'fix       kubectl --context fixture-context scale deployment/web -n demo --replicas=2'
if [[ "$(cat "$AUD_CALLS")" == *'--context fixture-context get deployments --namespace demo -o json'* ]]; then
  ok '--context and --namespace reach every get'
else
  err "--context/--namespace not passed through: $(cat "$AUD_CALLS")"
fi

reset_fixtures
export AUD_DEPLOYMENTS=kube-system-bad
run_audit --include-system
assert_rc '--include-system audits system namespaces' 0 "$rc"
assert_contains 'kube-system is audited on request' 'deployment kube-system/web: container web has no cpu request'
assert_contains 'gke-* namespaces are audited on request' 'deployment gke-managed-system/agent'

printf '\n--- Check selection and the per-check limit ---\n'
reset_fixtures
export AUD_DEPLOYMENTS=no-requests
run_audit --only probes
assert_rc '--only probes ignores a resources problem' 4 "$rc"
assert_absent '--only probes prints no other check' 'no cpu request'
assert_absent '--only probes has no resources heading' '== Resources'
calls="$(cat "$AUD_CALLS")"
if [[ "$calls" != *'get daemonsets'* && "$calls" != *'get cronjobs'* && "$calls" != *'get pdb'* ]]; then
  ok '--only probes lists only Deployments and StatefulSets'
else
  err "--only probes listed more than it needs: $calls"
fi
reset_fixtures
run_audit --only=resources,image-tag
if [[ "$(cat "$AUD_CALLS")" != *'get pdb'* ]]; then ok 'PodDisruptionBudgets are listed only for availability'; else err "pdb listed without availability: $(cat "$AUD_CALLS")"; fi
reset_fixtures
run_audit --only availability
if [[ "$(cat "$AUD_CALLS")" == *'get pdb'* ]]; then ok 'availability lists PodDisruptionBudgets'; else err "availability did not list pdb: $(cat "$AUD_CALLS")"; fi

reset_fixtures
export AUD_DEPLOYMENTS=many-bad
run_audit --only probes
assert_rc 'sixty offenders -> findings exit 0' 0 "$rc"
assert_contains 'rows past the limit are summarised' '... and 20 more (raise --limit)'
assert_contains 'hidden rows still count as findings' '60 finding(s)'
shown="$(grep -c 'has no readinessProbe' <<<"$out")"
if [[ "$shown" == "40" ]]; then ok 'the default limit prints 40 rows'; else err "printed $shown rows, expected 40"; fi
run_audit --only probes --limit 100
assert_absent '--limit 100 shows every row' 'raise --limit'

bare_path="$(mktemp -d)"
ln -s "$BASH" "$bare_path/bash"
if [[ -n "$TIMEOUT_BIN" ]]; then
  out="$(PATH="$bare_path" "$TIMEOUT_BIN" 20 "$SCRIPT" --list-checks 2>&1)"; rc=$?
else
  out="$(PATH="$bare_path" "$SCRIPT" --list-checks 2>&1)"; rc=$?
fi
assert_rc '--list-checks answers without kubectl' 0 "$rc"
for id in resources probes image-tag security availability; do
  assert_contains "--list-checks prints $id" "$id"
done
if [[ -n "$TIMEOUT_BIN" ]]; then
  out="$(PATH="$bare_path" "$TIMEOUT_BIN" 20 "$SCRIPT" 2>&1)"; rc=$?
else
  out="$(PATH="$bare_path" "$SCRIPT" 2>&1)"; rc=$?
fi
assert_rc 'missing kubectl -> exit 2' 2 "$rc"
rm -rf "$bare_path"
for args in '--only nosuch' '--only ,' '--limit 0' '--limit abc'; do
  # shellcheck disable=SC2086  # each case is two words on purpose
  run_audit $args
  assert_rc "$args -> 3" 3 "$rc"
done

printf '\n--- Failed queries and malformed JSON ---\n'
for resource in deployments statefulsets daemonsets cronjobs pdb; do
  for mode in query empty malformed missing-items invalid-items invalid-entry; do
    reset_fixtures
    case "$mode" in
      query) export AUD_FAIL_RESOURCE="$resource" ;;
      empty) export AUD_EMPTY_RESOURCE="$resource" ;;
      *) export AUD_BAD_RESOURCE="$resource" AUD_BAD_FIXTURE="$mode" ;;
    esac
    run_audit
    assert_rc "$resource $mode -> incomplete exit 1" 1 "$rc"
    assert_contains "$resource $mode reported" 'could not'
    assert_contains "$resource $mode incomplete summary" 'audit incomplete'
    assert_absent "$resource $mode cannot claim quiet" 'looks quiet'
    if [[ "$(cat "$AUD_CALLS")" == *'get pdb'* ]]; then
      ok "$resource $mode still listed the remaining kinds"
    else
      err "$resource $mode stopped early: $(cat "$AUD_CALLS")"
    fi
  done
done

printf '\n--- Read-only ---\n'
if [[ ! -s "$ALL_CALLS" ]]; then
  err 'no kubectl call was recorded; the read-only check would pass vacuously'
elif grep -Evq '^(--context [^ ]+ )?(get|cluster-info)( |$)' "$ALL_CALLS"; then
  err "a kubectl verb other than get/cluster-info ran: $(grep -Ev '^(--context [^ ]+ )?(get|cluster-info)( |$)' "$ALL_CALLS" | head -3)"
else
  ok 'only get and cluster-info were ever executed; fixes stay printed text'
fi

printf '\nWorkload audit failures: %s\n' "$failures"
(( failures == 0 ))
