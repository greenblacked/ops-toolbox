#!/usr/bin/env bash
# Exercise the RBAC review with secret-free kubectl fixtures.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../kubectl_rbac_audit.sh"
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
export RBAC_FIXTURE_DIR="$scratch"
RBAC_CALLS="$scratch/calls"
ALL_CALLS="$scratch/all-calls"
: > "$ALL_CALLS"
export RBAC_CALLS

# Bindings and roles shaped as the API returns them, including the built-in
# roles every cluster carries. The stub answers every query.
if ! python3 - "$scratch" <<'PY'
import json, pathlib, sys
root=pathlib.Path(sys.argv[1])
def save(name, items):
    (root/(name+'.json')).write_text(json.dumps({'items':items}))
def sa(name, ns):
    return {'kind':'ServiceAccount','name':name,'namespace':ns}
def user(name):
    return {'kind':'User','apiGroup':'rbac.authorization.k8s.io','name':name}
def group(name):
    return {'kind':'Group','apiGroup':'rbac.authorization.k8s.io','name':name}
def binding(name, role, subjects, ns=None, role_kind='ClusterRole'):
    meta={'name':name}
    if ns:
        meta['namespace']=ns
    return {'metadata':meta,'roleRef':{'apiGroup':'rbac.authorization.k8s.io','kind':role_kind,'name':role},'subjects':subjects}
def rule(verbs, resources, groups=('',), names=None):
    doc={'apiGroups':list(groups),'resources':list(resources),'verbs':list(verbs)}
    if names:
        doc['resourceNames']=list(names)
    return doc
def role(name, rules, ns=None):
    meta={'name':name}
    if ns:
        meta['namespace']=ns
    return {'metadata':meta,'rules':rules}
BUILTINS=[role('cluster-admin',[rule(['*'],['*'],['*'])]),
          role('admin',[rule(['get','list','watch','create','delete'],['secrets','pods'])]),
          role('edit',[rule(['get','list','watch','create','delete'],['secrets','pods'])]),
          role('view',[rule(['get','list','watch'],['pods','services'])]),
          role('system:aggregate-to-edit',[rule(['*'],['*'],['*'])]),
          role('system:kube-controller-manager',[rule(['get'],['secrets'])])]
save('empty', [])
save('crb-clean', [binding('cluster-admin','cluster-admin',[group('system:masters')]),
                   binding('system:kube-controller-manager','system:kube-controller-manager',[user('system:kube-controller-manager')])])
save('rb-clean', [binding('viewers','view',[group('auditors')],ns='demo')])
save('cr-clean', BUILTINS)
save('roles-clean', [role('pod-reader',[rule(['get','list'],['pods'])],ns='demo')])
save('crb-admin-sa', [binding('ci-deployer','cluster-admin',[sa('deployer','ci')])])
save('crb-admin-user', [binding('alice-admin','cluster-admin',[user('alice@example.com')])])
save('rb-admin-namespaced', [binding('team-admin','cluster-admin',[group('team-a')],ns='team-a')])
save('cr-wildcard', BUILTINS+[role('ops-all',[rule(['*'],['*'],['*'])])])
save('cr-wild-verbs', BUILTINS+[role('pod-all',[rule(['*'],['pods'])])])
save('roles-wild-verbs', [role('pod-admin',[rule(['*'],['pods'])],ns='demo')])
save('cr-wild-resources', BUILTINS+[role('read-all',[rule(['get'],['*'])])])
save('cr-wild-groups', BUILTINS+[role('read-any-group',[rule(['get'],['pods'],['*'])])])
save('cr-wild-urls', BUILTINS+[role('url-all',[{'nonResourceURLs':['*'],'verbs':['get']}])])
save('cr-wild-url-glob', BUILTINS+[role('health-all',[{'nonResourceURLs':['/healthz/*'],'verbs':['get']}])])
save('cr-url-exact', BUILTINS+[role('health-one',[{'nonResourceURLs':['/healthz'],'verbs':['get']}])])
save('cr-escalate', BUILTINS+[role('rbac-manager',[rule(['escalate','bind','get'],['clusterroles'],['rbac.authorization.k8s.io'])])])
save('rb-default-sa', [binding('app-edit','edit',[sa('default','demo')],ns='demo')])
save('crb-default-group-all', [binding('everyone','view',[group('system:serviceaccounts')])])
save('rb-default-group-ns', [binding('demo-sas','edit',[group('system:serviceaccounts:demo')],ns='demo')])
save('crb-admin-sa-group', [binding('all-sas-admin','cluster-admin',[group('system:serviceaccounts')])])
save('crb-default-group-other', [binding('some-group','view',[group('system:authenticated'),group('system:serviceaccounts-ops')])])
save('crb-default-sa-other', [binding('metrics-reader','view',[sa('default','other')])])
save('crb-dangling', [binding('old-ci','ci-deployer-v1',[sa('deployer','ci')])])
save('rb-dangling-role', [binding('reader-binding','reader',[user('bob')],ns='demo',role_kind='Role')])
save('roles-other-ns', [role('reader',[rule(['get'],['configmaps'])],ns='other')])
save('roles-same-ns', [role('reader',[rule(['get'],['configmaps'])],ns='demo')])
save('cr-secret-reader', BUILTINS+[role('secret-reader',[rule(['get','list'],['secrets'])])])
save('crb-secret-reader', [binding('ci-secrets','secret-reader',[sa('deployer','ci')])])
save('roles-secrets', [role('app-secrets',[rule(['get'],['secrets'])],ns='demo')])
save('rb-secrets', [binding('app-secrets','app-secrets',[sa('app','demo')],ns='demo',role_kind='Role')])
save('roles-secrets-limited', [role('tls-reader',[rule(['get'],['secrets'],names=['web-tls'])],ns='demo')])
save('rb-secrets-limited', [binding('tls-reader','tls-reader',[sa('ingress','demo')],ns='demo',role_kind='Role')])
save('roles-secrets-mixed', [role('mixed-reader',[rule(['get'],['secrets'],names=['web-tls']),rule(['list'],['secrets'])],ns='demo')])
save('rb-secrets-mixed', [binding('mixed-reader','mixed-reader',[sa('ingress','demo')],ns='demo',role_kind='Role')])
save('roles-secrets-other-group', [role('fake-secrets',[rule(['get'],['secrets'],['example.com'])],ns='demo')])
save('rb-secrets-other-group', [binding('fake-secrets','fake-secrets',[sa('app','demo')],ns='demo',role_kind='Role')])
save('crb-many', [binding('admin-%02d' % i,'cluster-admin',[user('user-%02d' % i)]) for i in range(60)])
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
printf '%s\n' "$*" >> "$RBAC_CALLS"
case " $* " in
  *" cluster-info "*) exit 0 ;;
  *" get clusterrolebindings "*) resource=clusterrolebindings; fixture="$RBAC_CRB" ;;
  *" get rolebindings "*) resource=rolebindings; fixture="$RBAC_RB" ;;
  *" get clusterroles "*) resource=clusterroles; fixture="$RBAC_CR" ;;
  *" get roles "*) resource=roles; fixture="$RBAC_ROLES" ;;
  *) printf 'unexpected stub command: %s\n' "$*" >&2; exit 99 ;;
esac
if [[ "$resource" == "$RBAC_FAIL_RESOURCE" ]]; then exit 1; fi
if [[ "$resource" == "$RBAC_EMPTY_RESOURCE" ]]; then exit 0; fi
if [[ "$resource" == "$RBAC_BAD_RESOURCE" ]]; then fixture="$RBAC_BAD_FIXTURE"; fi
cat "$RBAC_FIXTURE_DIR/$fixture.json"
KUBECTL
chmod +x "$scratch/kubectl" || { err 'could not make kubectl stub executable'; exit 1; }

TIMEOUT_BIN="$(command -v timeout || true)"
run_rbac() {
  : > "$RBAC_CALLS"
  if [[ -n "$TIMEOUT_BIN" ]]; then
    out="$(PATH="$scratch:$PATH" "$TIMEOUT_BIN" 20 "$SCRIPT" "$@" 2>&1)"; rc=$?
  else
    out="$(PATH="$scratch:$PATH" "$SCRIPT" "$@" 2>&1)"; rc=$?
  fi
  cat "$RBAC_CALLS" >> "$ALL_CALLS"
}
reset_fixtures() {
  export RBAC_CRB=crb-clean RBAC_RB=rb-clean RBAC_CR=cr-clean RBAC_ROLES=roles-clean
  export RBAC_FAIL_RESOURCE='' RBAC_EMPTY_RESOURCE='' RBAC_BAD_RESOURCE='' RBAC_BAD_FIXTURE=malformed
}

printf '\n--- A cluster with only system and read-only bindings ---\n'
reset_fixtures
run_rbac
assert_rc 'system:masters, built-in roles and a view binding -> quiet exit 4' 4 "$rc"
assert_contains 'quiet summary' 'RBAC looks quiet'
assert_absent 'no finding is printed' '[warn]'
calls="$(cat "$RBAC_CALLS")"
for query in 'get clusterrolebindings -o json' 'get rolebindings --all-namespaces -o json' \
             'get clusterroles -o json' 'get roles --all-namespaces -o json'; do
  if [[ "$calls" == *"$query"* ]]; then ok "queried: $query"; else err "missing query '$query': $calls"; fi
done
reset_fixtures
run_rbac --include-system
assert_rc '--include-system judges system subjects and built-in roles' 0 "$rc"
assert_contains 'system:masters is shown on request' 'clusterrolebinding cluster-admin -> cluster-admin: Group system:masters'
assert_contains 'built-in wildcard role is shown on request' 'clusterrole cluster-admin grants * on *'

printf '\n--- Each check, its row and its next step ---\n'
for case_ in \
  'RBAC_CRB|crb-admin-sa|[risk] clusterrolebinding ci-deployer -> cluster-admin: ServiceAccount ci/deployer|kubectl describe clusterrolebinding ci-deployer' \
  'RBAC_CRB|crb-admin-user|[risk] clusterrolebinding alice-admin -> cluster-admin: User alice@example.com|kubectl describe clusterrolebinding alice-admin' \
  'RBAC_RB|rb-admin-namespaced|[advice] rolebinding team-a/team-admin -> cluster-admin: Group team-a|kubectl describe rolebinding team-admin -n team-a' \
  'RBAC_CR|cr-wildcard|[risk] clusterrole ops-all grants * on * in apiGroups *|kubectl describe clusterrole ops-all' \
  'RBAC_CR|cr-wild-verbs|[advice] clusterrole pod-all grants wildcard verbs: * on pods in apiGroups core|kubectl describe clusterrole pod-all' \
  'RBAC_ROLES|roles-wild-verbs|[advice] role demo/pod-admin grants wildcard verbs: * on pods in apiGroups core|kubectl describe role pod-admin -n demo' \
  'RBAC_CR|cr-wild-resources|[advice] clusterrole read-all grants wildcard resources: get on * in apiGroups core|kubectl describe clusterrole read-all' \
  'RBAC_CR|cr-wild-groups|[advice] clusterrole read-any-group grants wildcard apiGroups: get on pods in apiGroups *|kubectl describe clusterrole read-any-group' \
  'RBAC_CR|cr-wild-urls|[advice] clusterrole url-all grants wildcard nonResourceURLs: get on - in apiGroups - (nonResourceURLs *)|kubectl describe clusterrole url-all' \
  'RBAC_CR|cr-wild-url-glob|[advice] clusterrole health-all grants wildcard nonResourceURLs: get on - in apiGroups - (nonResourceURLs /healthz/*)|kubectl describe clusterrole health-all' \
  'RBAC_CR|cr-escalate|[risk] clusterrole rbac-manager grants bind,escalate on clusterroles|kubectl describe clusterrole rbac-manager' \
  'RBAC_RB|rb-default-sa|[advice] rolebinding demo/app-edit -> edit: ServiceAccount demo/default|kubectl describe rolebinding app-edit -n demo' \
  'RBAC_CRB|crb-default-sa-other|[risk] clusterrolebinding metrics-reader -> view: ServiceAccount other/default|kubectl describe clusterrolebinding metrics-reader' \
  'RBAC_CRB|crb-dangling|[advice] clusterrolebinding old-ci -> ClusterRole ci-deployer-v1, which does not exist|kubectl delete clusterrolebinding old-ci' \
  'RBAC_RB|rb-dangling-role|[advice] rolebinding demo/reader-binding -> Role reader, which does not exist in namespace demo|kubectl delete rolebinding reader-binding -n demo'
do
  IFS='|' read -r var fixture want next <<<"$case_"
  reset_fixtures
  export "$var=$fixture"
  run_rbac
  assert_rc "$fixture -> findings exit 0" 0 "$rc"
  assert_contains "$fixture row" "$want"
  assert_contains "$fixture next step" "next      $next"
  assert_absent "$fixture is not quiet" 'RBAC looks quiet'
done

reset_fixtures
export RBAC_CR=cr-url-exact
run_rbac
assert_rc 'an exact non-resource URL is not a wildcard' 4 "$rc"

reset_fixtures
export RBAC_CRB=crb-default-group-all RBAC_RB=rb-default-group-ns
run_rbac --only default-sa
assert_rc 'ServiceAccount groups reach the default ServiceAccounts by default' 0 "$rc"
assert_contains 'all-ServiceAccounts group on a clusterrolebinding' '[risk] clusterrolebinding everyone -> view: Group system:serviceaccounts'
assert_contains 'per-namespace group on a rolebinding' '[advice] rolebinding demo/demo-sas -> edit: Group system:serviceaccounts:demo'
reset_fixtures
export RBAC_CRB=crb-default-group-other
run_rbac --only default-sa
assert_rc 'other system: groups do not name the default ServiceAccounts' 4 "$rc"
run_rbac --only default-sa --include-system
assert_rc 'other system: groups stay out of default-sa with --include-system' 4 "$rc"

reset_fixtures
export RBAC_CRB=crb-admin-sa-group
run_rbac --only cluster-admin
assert_rc 'a ServiceAccount group bound to cluster-admin is judged by default' 0 "$rc"
assert_contains 'cluster-admin row for a ServiceAccount group' '[risk] clusterrolebinding all-sas-admin -> cluster-admin: Group system:serviceaccounts'

reset_fixtures
export RBAC_RB=rb-dangling-role RBAC_ROLES=roles-other-ns
run_rbac
assert_contains 'a Role of the same name in another namespace does not count' 'Role reader, which does not exist in namespace demo'
reset_fixtures
export RBAC_RB=rb-dangling-role RBAC_ROLES=roles-same-ns
run_rbac
assert_rc 'a Role in the binding namespace resolves it' 4 "$rc"

reset_fixtures
export RBAC_CRB=crb-secret-reader RBAC_CR=cr-secret-reader
run_rbac
assert_rc 'cluster-wide Secret reader -> findings exit 0' 0 "$rc"
assert_contains 'cluster-wide grant is a risk with its binding' '[risk] clusterrole secret-reader can get, list secrets; bound to: clusterrolebinding ci-secrets (ServiceAccount ci/deployer)'
reset_fixtures
export RBAC_RB=rb-secrets RBAC_ROLES=roles-secrets
run_rbac
assert_contains 'namespaced grant is advice' '[advice] role demo/app-secrets can get secrets; bound to: rolebinding demo/app-secrets (ServiceAccount demo/app)'
reset_fixtures
export RBAC_RB=rb-secrets-limited RBAC_ROLES=roles-secrets-limited
run_rbac
assert_rc 'a resourceNames-limited grant is still reported' 0 "$rc"
assert_contains 'the limit is spelled out' '(limited by resourceNames: web-tls)'
reset_fixtures
export RBAC_RB=rb-secrets-mixed RBAC_ROLES=roles-secrets-mixed
run_rbac
assert_rc 'a role with a limited and an open Secret rule is reported' 0 "$rc"
assert_contains 'the open rule is listed' 'role demo/mixed-reader can get, list secrets; bound to:'
assert_absent 'the limit is not claimed when another rule reads every Secret' 'limited by resourceNames'
reset_fixtures
export RBAC_RB=rb-secrets-other-group RBAC_ROLES=roles-secrets-other-group
run_rbac
assert_rc '"secrets" in another API group is not core Secrets' 4 "$rc"
reset_fixtures
export RBAC_ROLES=roles-secrets
run_rbac
assert_rc 'a Secret-reading role nothing binds grants nothing' 4 "$rc"

reset_fixtures
export RBAC_CRB=crb-admin-sa
run_rbac --context fixture-context --namespace demo
assert_contains 'next step names the context that was read' 'next      kubectl --context fixture-context describe clusterrolebinding ci-deployer'
calls="$(cat "$RBAC_CALLS")"
if [[ "$calls" == *'--context fixture-context get rolebindings --namespace demo -o json'* &&
      "$calls" == *'--context fixture-context get clusterrolebindings -o json'* ]]; then
  ok '--namespace narrows RoleBindings while ClusterRoleBindings stay cluster-wide'
else
  err "unexpected scoping: $calls"
fi

reset_fixtures
export RBAC_CRB=crb-many
run_rbac --only cluster-admin
assert_contains 'rows past 40 are summarised' '... and 20 more'
assert_contains 'hidden rows still count' '60 finding(s)'
shown="$(grep -c -- '-> cluster-admin: User user-' <<<"$out")"
if [[ "$shown" == "40" ]]; then ok 'at most 40 rows per check'; else err "printed $shown rows, expected 40"; fi

printf '\n--- Check selection ---\n'
reset_fixtures
run_rbac --only cluster-admin
calls="$(cat "$RBAC_CALLS")"
if [[ "$calls" == *'get clusterrolebindings'* && "$calls" == *'get rolebindings'* &&
      "$calls" != *'get clusterroles'* && "$calls" != *'get roles'* ]]; then
  ok '--only cluster-admin reads bindings only'
else
  err "--only cluster-admin queried: $calls"
fi
run_rbac --only wildcard
calls="$(cat "$RBAC_CALLS")"
if [[ "$calls" != *'bindings'* && "$calls" == *'get clusterroles'* && "$calls" == *'get roles'* ]]; then
  ok '--only wildcard reads roles only'
else
  err "--only wildcard queried: $calls"
fi
run_rbac --only dangling
gets="$(grep -cE '(^| )get ' "$RBAC_CALLS")"
if [[ "$gets" == "4" ]]; then ok '--only dangling reads bindings and roles (four gets)'; else err "--only dangling issued $gets gets"; fi
reset_fixtures
export RBAC_CR=cr-wild-verbs
run_rbac --only wildcard
assert_rc '--only wildcard catches verbs * on a named resource' 0 "$rc"
assert_contains '--only wildcard names the role' 'clusterrole pod-all grants wildcard verbs'
reset_fixtures
export RBAC_CR=cr-wild-resources
run_rbac --only wildcard
assert_rc '--only wildcard catches a named verb on resources *' 0 "$rc"
assert_contains '--only wildcard names the resources role' 'clusterrole read-all grants wildcard resources'
reset_fixtures
export RBAC_CRB=crb-admin-sa
run_rbac --only wildcard
assert_rc '--only wildcard ignores a cluster-admin binding' 4 "$rc"

bare_path="$(mktemp -d)"
ln -s "$BASH" "$bare_path/bash"
if [[ -n "$TIMEOUT_BIN" ]]; then
  out="$(PATH="$bare_path" "$TIMEOUT_BIN" 20 "$SCRIPT" --list-checks 2>&1)"; rc=$?
else
  out="$(PATH="$bare_path" "$SCRIPT" --list-checks 2>&1)"; rc=$?
fi
assert_rc '--list-checks answers without kubectl' 0 "$rc"
for id in cluster-admin wildcard default-sa dangling secrets; do
  assert_contains "--list-checks prints $id" "$id"
done
if [[ -n "$TIMEOUT_BIN" ]]; then
  out="$(PATH="$bare_path" "$TIMEOUT_BIN" 20 "$SCRIPT" 2>&1)"; rc=$?
else
  out="$(PATH="$bare_path" "$SCRIPT" 2>&1)"; rc=$?
fi
assert_rc 'missing kubectl -> exit 2' 2 "$rc"
rm -rf "$bare_path"
run_rbac --only nosuch
assert_rc '--only with an unknown id -> 3' 3 "$rc"
run_rbac --only ,
assert_rc '--only selecting nothing -> 3' 3 "$rc"

printf '\n--- Failed queries and malformed JSON ---\n'
for resource in clusterrolebindings rolebindings clusterroles roles; do
  for mode in query empty malformed missing-items invalid-items invalid-entry; do
    reset_fixtures
    case "$mode" in
      query) export RBAC_FAIL_RESOURCE="$resource" ;;
      empty) export RBAC_EMPTY_RESOURCE="$resource" ;;
      *) export RBAC_BAD_RESOURCE="$resource" RBAC_BAD_FIXTURE="$mode" ;;
    esac
    run_rbac
    assert_rc "$resource $mode -> incomplete exit 1" 1 "$rc"
    assert_contains "$resource $mode reported" 'could not'
    assert_contains "$resource $mode incomplete summary" 'RBAC audit incomplete'
    assert_absent "$resource $mode cannot claim quiet" 'RBAC looks quiet'
    if [[ "$(cat "$RBAC_CALLS")" == *'get roles'* ]]; then
      ok "$resource $mode still ran the remaining queries"
    else
      err "$resource $mode stopped early: $(cat "$RBAC_CALLS")"
    fi
  done
done
reset_fixtures
export RBAC_CRB=crb-admin-sa RBAC_FAIL_RESOURCE=roles
run_rbac
assert_contains 'findings survive a later failed query' 'ci-deployer -> cluster-admin'
assert_rc 'query failure takes precedence over findings' 1 "$rc"

printf '\n--- Read-only ---\n'
# The output legitimately prints "kubectl delete" as a next step; the call log
# is what proves nothing but reads ever ran.
if [[ ! -s "$ALL_CALLS" ]]; then
  err 'no kubectl call was recorded; the read-only check would pass vacuously'
elif grep -Eq '(delete|create|patch|apply|edit|auth|impersonate|--as)' "$ALL_CALLS"; then
  err "a mutating or impersonating kubectl call ran: $(grep -E '(delete|create|patch|apply|edit|auth|impersonate|--as)' "$ALL_CALLS" | head -3)"
elif grep -Evq '^(--context [^ ]+ )?(get|cluster-info)( |$)' "$ALL_CALLS"; then
  err "a kubectl verb other than get/cluster-info ran: $(grep -Ev '^(--context [^ ]+ )?(get|cluster-info)( |$)' "$ALL_CALLS" | head -3)"
else
  ok 'only get and cluster-info were ever executed'
fi

printf '\nRBAC audit failures: %s\n' "$failures"
(( failures == 0 ))
