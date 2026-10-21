#!/usr/bin/env bash
# Exercise the dead-pod cleanup preview and --yes gate with a recording kubectl stub.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../kubectl_pod_cleanup.sh"
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
export CLEAN_FIXTURE_DIR="$scratch"
CLEAN_CALLS="$scratch/calls"
CLEAN_DELETED="$scratch/deleted"
export CLEAN_CALLS CLEAN_DELETED

# Pods in every phase, with ages kept well away from the boundaries the
# assertions use. The stub records every call and every pod it "deletes".
if ! python3 - "$scratch" <<'PY'
import datetime, json, pathlib, sys
root=pathlib.Path(sys.argv[1])
now=datetime.datetime.now(datetime.timezone.utc)
ago=lambda **kw: (now-datetime.timedelta(**kw)).replace(microsecond=0).isoformat().replace('+00:00','Z')
def save(name, items):
    (root/(name+'.json')).write_text(json.dumps({'items':items}))
def pod(name, phase, started=None, finished=None, created=None, reason=None, deleting=False, ns='demo'):
    meta={'namespace':ns,'name':name,'creationTimestamp':created or started or ago(days=30)}
    if deleting:
        meta['deletionTimestamp']=ago(minutes=1)
    status={'phase':phase}
    if started:
        status['startTime']=started
    if reason:
        status['reason']=reason
    if finished:
        status['containerStatuses']=[{'name':'main','state':{'terminated':{'exitCode':1 if phase == 'Failed' else 0,'finishedAt':finished}}}]
    return {'metadata':meta,'status':status}
# Ages sit well away from each boundary the suite asks about (30m, 1d, 3d).
failed_old=pod('job-a-1','Failed',started=ago(hours=50),finished=ago(hours=49))
failed_recent=pod('job-b-1','Failed',started=ago(minutes=50),finished=ago(minutes=45))
evicted=pod('web-evicted-1','Failed',started=ago(days=4),reason='Evicted')
succeeded_old=pod('report-1','Succeeded',started=ago(hours=50),finished=ago(hours=49))
running_old=pod('web-1','Running',started=ago(days=10))
pending_old=pod('web-2','Pending',created=ago(days=10))
terminating=pod('job-c-1','Failed',started=ago(days=5),finished=ago(days=5),deleting=True)
no_time=pod('job-d-1','Failed',created='invalid')
save('mixed', [running_old,failed_old,failed_recent,evicted,succeeded_old,pending_old,terminating,no_time])
save('failed-old', [failed_old])
save('nothing', [running_old,pending_old,failed_recent])
save('many', [pod('batch-%03d' % i,'Failed',started=ago(hours=50),finished=ago(hours=49)) for i in range(250)])
save('other-ns', [pod('job-a-1','Failed',started=ago(hours=50),finished=ago(hours=49),ns='other')])
(root/'malformed.json').write_text('{broken')
(root/'missing-items.json').write_text('{}')
(root/'invalid-entry.json').write_text('{"items":[null]}')
PY
then
  err 'could not generate JSON fixtures'
  exit 1
fi

cat > "$scratch/bin/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "$CLEAN_CALLS"
case " $* " in
  *" cluster-info "*)
    if [[ -n "$CLEAN_CLUSTER_DOWN" ]]; then exit 1; fi
    exit 0
    ;;
  *" config current-context "*) printf 'fixture-context\n'; exit 0 ;;
  *" get pods "*)
    if [[ -n "$CLEAN_LIST_FAIL" ]]; then exit 1; fi
    cat "$CLEAN_FIXTURE_DIR/$CLEAN_PODS.json"
    exit 0
    ;;
  *" delete pod "*)
    name=""; ns=""; prev=""
    for arg in "$@"; do
      if [[ "$prev" == "pod" ]]; then name="$arg"; fi
      if [[ "$prev" == "--namespace" ]]; then ns="$arg"; fi
      prev="$arg"
    done
    for bad in $CLEAN_FAIL; do
      if [[ "$name" == "$bad" ]]; then
        printf 'Error from server (Forbidden): pods "%s" is forbidden\n' "$name" >&2
        exit 1
      fi
    done
    for gone in $CLEAN_GONE; do
      if [[ "$name" == "$gone" ]]; then
        printf 'Error from server (NotFound): pods "%s" not found\n' "$name" >&2
        exit 1
      fi
    done
    printf '%s/%s\n' "$ns" "$name" >> "$CLEAN_DELETED"
    exit 0
    ;;
  *) printf 'unexpected stub command: %s\n' "$*" >&2; exit 99 ;;
esac
KUBECTL
chmod +x "$scratch/bin/kubectl" || { err 'could not make kubectl stub executable'; exit 1; }

TIMEOUT_BIN="$(command -v timeout || true)"
run_with_path() {
  local path="$1"
  shift
  : > "$CLEAN_CALLS"
  : > "$CLEAN_DELETED"
  if [[ -n "$TIMEOUT_BIN" ]]; then
    out="$(PATH="$path" "$TIMEOUT_BIN" 20 "$SCRIPT" "$@" 2>&1)"; rc=$?
  else
    out="$(PATH="$path" "$SCRIPT" "$@" 2>&1)"; rc=$?
  fi
}
run_clean() { run_with_path "$scratch/bin:$PATH" "$@"; }
reset_fixtures() {
  export CLEAN_PODS=mixed CLEAN_FAIL='' CLEAN_GONE='' CLEAN_CLUSTER_DOWN='' CLEAN_LIST_FAIL=''
}
deletes() { grep -cE '(^| )delete ' "$CLEAN_CALLS"; }
deleted_set() { sort "$CLEAN_DELETED" | tr '\n' ' '; }

printf '\n--- The default run is a preview ---\n'
reset_fixtures
run_clean
assert_rc 'bare invocation previews and exits 0' 0 "$rc"
assert_contains 'context is named' 'context   fixture-context'
assert_contains 'scope is named' 'scope     all namespaces'
assert_contains 'the preview says nothing is deleted' 'mode      preview: nothing is deleted'
assert_contains 'old Failed pod is previewed' 'dry-run: would run: kubectl delete pod job-a-1 --namespace demo --wait=false'
assert_contains 'Evicted pod is previewed with its reason' 'pod demo/web-evicted-1: Failed (Evicted)'
assert_contains 'preview closes with the completion line' 'dry-run complete; no changes written'
assert_contains 'preview says how to apply' 're-run with --yes to delete 2 pod(s)'
for absent in job-b-1 report-1 web-1 web-2 job-c-1 job-d-1; do
  assert_absent "preview leaves $absent alone" "pod $absent "
done
if [[ "$(deletes)" == "0" ]]; then ok 'a preview issues no delete'; else err "preview deleted: $(cat "$CLEAN_CALLS")"; fi
run_clean --yes --dry-run
assert_rc '--yes --dry-run still previews' 0 "$rc"
if [[ "$(deletes)" == "0" ]]; then ok '--dry-run wins over --yes'; else err "--yes --dry-run deleted: $(cat "$CLEAN_CALLS")"; fi

printf '\n--- --yes deletes exactly the listed pods ---\n'
reset_fixtures
run_clean --yes
assert_rc '--yes deletes and exits 0' 0 "$rc"
if [[ "$(deleted_set)" == 'demo/job-a-1 demo/web-evicted-1 ' ]]; then
  ok 'only the old Failed and Evicted pods were deleted'
else
  err "unexpected deletions: $(deleted_set)"
fi
calls="$(grep -E '(^| )delete ' "$CLEAN_CALLS")"
if [[ -n "$calls" ]] && ! grep -v -- '--namespace demo --wait=false' <<<"$calls" | grep -q .; then
  ok 'every delete names its namespace and does not wait'
else
  err "delete calls without --namespace/--wait=false: $calls"
fi
if grep -Eq -- '--force|--grace-period|--all|-l |--selector|--field-selector' <<<"$calls"; then
  err "a delete used a blanket or forced form: $calls"
else
  ok 'no --force, no --grace-period, no selector: names only'
fi
assert_contains 'the mode is announced before deleting' 'mode      delete (--yes)'
assert_contains 'the summary counts the deletions' 'deleted 2, already gone 0, failed 0'

run_clean --yes --include-succeeded
if [[ "$(deleted_set)" == 'demo/job-a-1 demo/report-1 demo/web-evicted-1 ' ]]; then
  ok '--include-succeeded adds the old Succeeded pod'
else
  err "--include-succeeded deleted: $(deleted_set)"
fi
run_clean --yes --older-than 30m
if [[ "$(deleted_set)" == 'demo/job-a-1 demo/job-b-1 demo/web-evicted-1 ' ]]; then
  ok '--older-than 30m reaches the recent failure'
else
  err "--older-than 30m deleted: $(deleted_set)"
fi
run_clean --yes --older-than=3d --context other-context
if [[ "$(deleted_set)" == 'demo/web-evicted-1 ' ]]; then
  ok '--older-than=3d keeps the two-day-old failure'
else
  err "--older-than 3d deleted: $(deleted_set)"
fi
assert_contains '--context is the context shown' 'context   other-context'
if grep -q -- '^--context other-context delete pod web-evicted-1 --namespace demo --wait=false$' "$CLEAN_CALLS"; then
  ok 'deletes go to the --context that was listed'
else
  err "delete did not carry --context: $(cat "$CLEAN_CALLS")"
fi

export CLEAN_PODS=other-ns
run_clean --yes --namespace other
if [[ "$(cat "$CLEAN_CALLS")" == *'get pods --namespace other -o json'* && "$(deleted_set)" == 'other/job-a-1 ' ]]; then
  ok '--namespace narrows the listing and the delete'
else
  err "--namespace not honoured: $(cat "$CLEAN_CALLS")"
fi

reset_fixtures
export CLEAN_FAIL=job-a-1
run_clean --yes
assert_rc 'one failing delete -> exit 1' 1 "$rc"
if [[ "$(deleted_set)" == 'demo/web-evicted-1 ' ]]; then ok 'the remaining deletes still ran'; else err "after a failure: $(deleted_set)"; fi
assert_contains 'the failure is named' 'could not delete demo/job-a-1'
reset_fixtures
export CLEAN_GONE=job-a-1
run_clean --yes
assert_rc 'a pod already gone counts as done' 0 "$rc"
assert_contains 'already gone is reported' 'already gone: demo/job-a-1'

printf '\n--- Nothing to do, too much to do, nothing to read ---\n'
reset_fixtures
export CLEAN_PODS=nothing
run_clean
assert_rc 'no matching pod -> exit 4' 4 "$rc"
run_clean --yes
assert_rc 'no matching pod with --yes -> exit 4' 4 "$rc"
if [[ "$(deletes)" == "0" ]]; then ok 'nothing matching deletes nothing'; else err "deleted with nothing matching"; fi

reset_fixtures
export CLEAN_PODS=many
for mode in '' '--yes'; do
  # shellcheck disable=SC2086  # an empty mode must add no argument
  run_clean $mode
  assert_rc "250 matches over --max 200 ${mode:-(preview)} -> exit 3" 3 "$rc"
  assert_contains "the cap is explained ${mode:-(preview)}" '250 pods match; raise --max or narrow with --namespace/--older-than'
  if [[ "$(deletes)" == "0" ]]; then ok "the cap deletes nothing ${mode:-(preview)}"; else err 'the cap still deleted'; fi
done
run_clean --yes --max 300
assert_rc '--max 300 lets 250 through' 0 "$rc"
if [[ "$(deletes)" == "250" ]]; then ok 'all 250 deleted one by one'; else err "deleted $(deletes) of 250"; fi

reset_fixtures
export CLEAN_LIST_FAIL=1
run_clean --yes
assert_rc 'a failed listing -> exit 1' 1 "$rc"
assert_contains 'the listing failure is named' 'could not list pods'
for fixture in malformed missing-items invalid-entry; do
  reset_fixtures
  export CLEAN_PODS="$fixture"
  run_clean --yes
  assert_rc "$fixture pods JSON -> exit 1" 1 "$rc"
  if [[ "$(deletes)" == "0" ]]; then ok "$fixture deletes nothing"; else err "$fixture still deleted"; fi
done

printf '\n--- Without kubectl or a cluster ---\n'
reset_fixtures
bare_path="$(mktemp -d)"
ln -s "$BASH" "$bare_path/bash"
run_with_path "$bare_path" --dry-run
assert_rc 'a preview without kubectl still answers' 0 "$rc"
assert_contains 'it names what is missing' 'kubectl is not installed'
assert_contains 'it prints the listing command' 'dry-run: would run: kubectl get pods --all-namespaces -o json'
assert_contains 'it closes the preview' 'dry-run complete; no changes written'
run_with_path "$bare_path" --yes
assert_rc 'deleting without kubectl -> exit 2' 2 "$rc"
rm -rf "$bare_path"
export CLEAN_CLUSTER_DOWN=1
run_clean
assert_rc 'a preview with the cluster down still answers' 0 "$rc"
assert_contains 'the unreachable cluster is named' 'cannot reach the cluster'
run_clean --yes
assert_rc 'deleting with the cluster down -> exit 2' 2 "$rc"
if [[ "$(deletes)" == "0" ]]; then ok 'nothing deleted with the cluster down'; else err 'deleted with the cluster down'; fi

printf '\n--- Usage ---\n'
reset_fixtures
for args in '--older-than yesterday' '--older-than 0d' '--older-than 5' '--max 0' '--max abc' '--max -1'; do
  # shellcheck disable=SC2086  # each case is two words on purpose
  run_clean $args
  assert_rc "$args -> 3" 3 "$rc"
  if [[ ! -s "$CLEAN_CALLS" ]]; then ok "$args never reaches kubectl"; else err "$args called kubectl"; fi
done

printf '\n--- A preview writes nothing ---\n'
snapshot() {
  find "$1" "$2" -mindepth 1 -printf '%p %T@\n' 2>/dev/null | sort
}
# -printf is GNU-only; fall back the way test_k8s_toolbox.sh does.
if ! find "$scratch" -maxdepth 0 -printf '' >/dev/null 2>&1; then
  snapshot() { find "$1" "$2" -mindepth 1 -exec ls -ld {} + 2>/dev/null | sort; }
fi
reset_fixtures
mkdir -p "$scratch/home" "$scratch/tmp"
: > "$scratch/home/.keep"
before="$(snapshot "$scratch/home" "$scratch/tmp")"
: > "$CLEAN_CALLS"
out="$(HOME="$scratch/home" TMPDIR="$scratch/tmp" PATH="$scratch/bin:$PATH" "$SCRIPT" 2>&1)"; rc=$?
after="$(snapshot "$scratch/home" "$scratch/tmp")"
if (( rc == 0 )) && [[ -n "$before" && "$before" == "$after" ]]; then
  ok 'a preview leaves HOME and TMPDIR untouched'
else
  err "a preview changed HOME/TMPDIR or failed (exit $rc)"
fi

printf '\nPod cleanup failures: %s\n' "$failures"
(( failures == 0 ))
