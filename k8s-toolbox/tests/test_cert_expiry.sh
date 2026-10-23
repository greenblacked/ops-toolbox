#!/usr/bin/env bash
# Exercise TLS certificate expiry reporting with secret-free kubectl and openssl stubs.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../kubectl_cert_expiry.sh"
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
mkdir -p "$scratch/kbin" "$scratch/obin"
export CERT_FIXTURE_DIR="$scratch"
CERT_CALLS="$scratch/calls"
CERT_OPENSSL_CALLS="$scratch/openssl-calls"
ALL_CALLS="$scratch/all-calls"
ALL_OUT="$scratch/all-out"
: > "$ALL_CALLS"; : > "$ALL_OUT"; : > "$CERT_OPENSSL_CALLS"
export CERT_CALLS CERT_OPENSSL_CALLS

# The certificates are stand-ins: tls.crt holds a marker such as
# FIXTURE-EXPIRING, and the openssl stub answers with an end date computed
# here, so no assertion depends on the host openssl or on date arithmetic in
# the shell. Every tls.key holds a canary that must never be printed.
if ! python3 - "$scratch" <<'PY'
import base64, datetime, json, pathlib, sys
root=pathlib.Path(sys.argv[1])
now=datetime.datetime.now(datetime.timezone.utc)
MONTHS=['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec']
# Half-day offsets keep every expected "Nd" away from a day boundary however
# long the run takes.
ends={'FIXTURE-OK-FAR':400.5,'FIXTURE-EXPIRING':12.5,'FIXTURE-SOON':5.5,'FIXTURE-EXPIRED':-3.5}
with open(root/'openssl-dates','w') as dates:
    for marker,days in ends.items():
        end=now+datetime.timedelta(days=days)
        dates.write('%s notAfter=%s %2d %02d:%02d:%02d %d GMT\n' % (
            marker,MONTHS[end.month-1],end.day,end.hour,end.minute,end.second,end.year))
b64=lambda text: base64.b64encode(text.encode()).decode()
KEY=b64('-----BEGIN PRIVATE KEY-----\nPRIVATE-KEY-CANARY\n-----END PRIVATE KEY-----\n')
(root/'key-b64').write_text(KEY)
def save(name, items):
    (root/(name+'.json')).write_text(json.dumps({'items':items}))
def secret(name, marker=None, crt=None):
    data={'tls.key':KEY}
    if marker is not None:
        data['tls.crt']=b64(marker)
    if crt is not None:
        data['tls.crt']=crt
    return {'metadata':{'namespace':'demo','name':name},'type':'kubernetes.io/tls','data':data}
save('empty', [])
save('ok-far', [secret('far-tls','FIXTURE-OK-FAR')])
save('expiring', [secret('web-tls','FIXTURE-EXPIRING')])
save('expired', [secret('old-tls','FIXTURE-EXPIRED')])
save('missing-crt', [secret('half-tls')])
save('broken', [secret('bad-tls','FIXTURE-BROKEN')])
save('not-base64', [secret('mangled-tls',crt='!!!not base64!!!')])
save('ordering', [secret('late-tls','FIXTURE-EXPIRING'),secret('gone-tls','FIXTURE-EXPIRED'),
                  secret('soon-tls','FIXTURE-SOON'),secret('far-tls','FIXTURE-OK-FAR')])
def at(days):
    return (now+datetime.timedelta(days=days)).replace(microsecond=0).isoformat().replace('+00:00','Z')
def certificate(name, days=None, ready=True, renewal=None, message=''):
    status={'conditions':[{'type':'Ready','status':'True' if ready else 'False','reason':'Ready' if ready else 'DoesNotExist','message':message}]}
    if days is not None:
        status['notAfter']=at(days)
    if renewal is not None:
        status['renewalTime']=at(renewal)
    return {'metadata':{'namespace':'demo','name':name},'spec':{'secretName':name+'-tls'},'status':status}
save('cm-ok', [certificate('far',400.5,renewal=370.5)])
save('cm-not-ready', [certificate('pending',ready=False,message='Issuing certificate as Secret does not exist')])
save('cm-expiring', [certificate('web',12.5,renewal=2.5)])
(root/'malformed.json').write_text('{broken')
(root/'missing-items.json').write_text('{}')
(root/'invalid-items.json').write_text('{"items":{}}')
(root/'invalid-entry.json').write_text('{"items":[null]}')
PY
then
  err 'could not generate JSON fixtures'
  exit 1
fi
KEY_B64="$(cat "$scratch/key-b64")"

cat > "$scratch/kbin/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "$CERT_CALLS"
case " $* " in
  *" cluster-info "*) exit 0 ;;
  *" get secrets "*) resource=secrets; fixture="$CERT_SECRETS" ;;
  *" get certificates.cert-manager.io "*) resource=certificates; fixture="$CERT_CERTIFICATES" ;;
  *) printf 'unexpected stub command: %s\n' "$*" >&2; exit 99 ;;
esac
if [[ "$resource" == "$CERT_FAIL_RESOURCE" ]]; then exit 1; fi
if [[ "$resource" == "$CERT_EMPTY_RESOURCE" ]]; then exit 0; fi
if [[ "$resource" == "$CERT_BAD_RESOURCE" ]]; then fixture="$CERT_BAD_FIXTURE"; fi
cat "$CERT_FIXTURE_DIR/$fixture.json"
KUBECTL
# Records what it was asked and what it was fed, so the suite can prove the
# private key never reached it.
cat > "$scratch/obin/openssl" <<'OPENSSL'
#!/usr/bin/env bash
set -uo pipefail
printf 'openssl %s\n' "$*" >> "$CERT_OPENSSL_CALLS"
marker="$(cat)"
printf '%s\n' "$marker" >> "$CERT_OPENSSL_CALLS"
[[ -n "$marker" && "$marker" != "FIXTURE-BROKEN" ]] || exit 1
line="$(grep -F -- "$marker notAfter=" "$CERT_FIXTURE_DIR/openssl-dates" | head -n 1)"
[[ -n "$line" ]] || exit 1
printf '%s\n' "${line#* }"
OPENSSL
chmod +x "$scratch/kbin/kubectl" "$scratch/obin/openssl" || { err 'could not make stubs executable'; exit 1; }

TIMEOUT_BIN="$(command -v timeout || true)"
run_with_path() {
  local path="$1"
  shift
  : > "$CERT_CALLS"
  if [[ -n "$TIMEOUT_BIN" ]]; then
    out="$(PATH="$path" "$TIMEOUT_BIN" 20 "$SCRIPT" "$@" 2>&1)"; rc=$?
  else
    out="$(PATH="$path" "$SCRIPT" "$@" 2>&1)"; rc=$?
  fi
  cat "$CERT_CALLS" >> "$ALL_CALLS"
  printf '%s\n' "$out" >> "$ALL_OUT"
}
run_cert() { run_with_path "$scratch/kbin:$scratch/obin:$PATH" "$@"; }
reset_fixtures() {
  export CERT_SECRETS=ok-far CERT_CERTIFICATES=cm-ok
  export CERT_FAIL_RESOURCE='' CERT_EMPTY_RESOURCE='' CERT_BAD_RESOURCE='' CERT_BAD_FIXTURE=malformed
}

printf '\n--- Expiry windows ---\n'
reset_fixtures
run_cert
assert_rc 'certificate 400 days out -> quiet exit 4' 4 "$rc"
assert_contains 'quiet run counts what it checked' 'checked 1 certificate(s), 0 within 30 days'
assert_contains 'quiet summary' 'certificates look quiet (none ends within 30 days)'
if [[ "$(cat "$CERT_CALLS")" == *'get secrets --all-namespaces --field-selector type=kubernetes.io/tls -o json'* ]]; then
  ok 'only kubernetes.io/tls Secrets are listed, across every namespace'
else
  err "unexpected secrets query: $(cat "$CERT_CALLS")"
fi

reset_fixtures
export CERT_SECRETS=expiring
run_cert
assert_rc 'certificate ending in 12 days -> findings exit 0' 0 "$rc"
assert_contains 'expiring certificate is named with its days left' 'secret demo/web-tls: EXPIRING in 12d ('
assert_contains 'expiring certificate has a printed next step' 'next      kubectl get secret web-tls -n demo -o jsonpath='
assert_contains 'expiring run counts it' 'checked 1 certificate(s), 1 within 30 days'
assert_absent 'expiring certificate is not quiet' 'look quiet'
run_cert --warn-days 5
assert_rc '--warn-days 5 leaves a 12-day certificate alone' 4 "$rc"
run_cert --warn-days=13 --context fixture-context --namespace demo
assert_rc '--warn-days=13 includes it again' 0 "$rc"
assert_contains 'next step names the context that was read' 'next      kubectl --context fixture-context get secret web-tls -n demo'
if [[ "$(cat "$CERT_CALLS")" == *'--context fixture-context get secrets --namespace demo --field-selector type=kubernetes.io/tls -o json'* ]]; then
  ok '--context and --namespace reach the query'
else
  err "--context/--namespace not passed through: $(cat "$CERT_CALLS")"
fi

reset_fixtures
export CERT_SECRETS=expired
run_cert
assert_rc 'expired certificate -> findings exit 0' 0 "$rc"
assert_contains 'expired certificate says how long ago' 'secret demo/old-tls: EXPIRED 3d ago ('

reset_fixtures
run_cert --warn-days 500
assert_rc '--warn-days 500 reaches the 400-day certificate' 0 "$rc"
assert_contains 'long window reports it' 'secret demo/far-tls: EXPIRING in 400d ('

reset_fixtures
export CERT_SECRETS=ordering
run_cert
assert_rc 'mixed expiries -> findings exit 0' 0 "$rc"
order="$(grep -oE '(gone|soon|late|far)-tls: (EXPIR|UNREAD)' <<<"$out" | cut -d- -f1 | tr '\n' ' ')"
if [[ "$order" == 'gone soon late ' ]]; then
  ok 'findings are sorted soonest first and the far one stays counted only'
else
  err "unexpected order '$order': $out"
fi
assert_contains 'every certificate is counted' 'checked 4 certificate(s), 3 within 30 days'

printf '\n--- Unreadable certificates are findings, not silent skips ---\n'
for case_ in \
  'missing-crt|secret demo/half-tls: UNREADABLE (no tls.crt)' \
  'broken|secret demo/bad-tls: UNREADABLE (openssl could not read tls.crt)' \
  'not-base64|secret demo/mangled-tls: UNREADABLE (tls.crt is not base64)'
do
  IFS='|' read -r fixture want <<<"$case_"
  reset_fixtures
  export CERT_SECRETS="$fixture"
  run_cert
  assert_rc "$fixture -> findings exit 0" 0 "$rc"
  assert_contains "$fixture is reported" "$want"
done

printf '\n--- cert-manager Certificates are opt-in ---\n'
reset_fixtures
run_cert
if [[ "$(cat "$CERT_CALLS")" != *'certificates.cert-manager.io'* ]]; then
  ok 'without --cert-manager no Certificate is listed'
else
  err "Certificates listed without --cert-manager: $(cat "$CERT_CALLS")"
fi
run_cert --cert-manager
assert_rc 'healthy Certificates stay quiet' 4 "$rc"
cm_gets="$(grep -c 'get certificates.cert-manager.io' "$CERT_CALLS")"
if [[ "$cm_gets" == "1" ]]; then ok '--cert-manager adds exactly one query'; else err "--cert-manager issued $cm_gets queries"; fi
assert_contains 'Certificate resources are counted' 'checked 1 Certificate resource(s)'
reset_fixtures
export CERT_CERTIFICATES=cm-not-ready
run_cert --cert-manager
assert_rc 'Certificate with Ready=False -> findings exit 0' 0 "$rc"
assert_contains 'Ready=False message is shown' 'certificate demo/pending: not Ready: Issuing certificate as Secret does not exist'
assert_contains 'Ready=False has a printed next step' 'next      kubectl describe certificate pending -n demo'
reset_fixtures
export CERT_CERTIFICATES=cm-expiring
run_cert --cert-manager
assert_rc 'expiring Certificate -> findings exit 0' 0 "$rc"
assert_contains 'expiring Certificate shows its renewal time' 'certificate demo/web: EXPIRING in 12d ('
assert_contains 'renewal time is shown' ', renewal due '

printf '\n--- Failed queries and malformed JSON ---\n'
for resource in secrets certificates; do
  for mode in query empty malformed missing-items invalid-items invalid-entry; do
    reset_fixtures
    case "$mode" in
      query) export CERT_FAIL_RESOURCE="$resource" ;;
      empty) export CERT_EMPTY_RESOURCE="$resource" ;;
      *) export CERT_BAD_RESOURCE="$resource" CERT_BAD_FIXTURE="$mode" ;;
    esac
    run_cert --cert-manager
    assert_rc "$resource $mode -> incomplete check exit 1" 1 "$rc"
    assert_contains "$resource $mode reported" 'could not'
    assert_contains "$resource $mode incomplete summary" 'certificate check incomplete'
    assert_absent "$resource $mode cannot claim quiet" 'look quiet'
    if [[ "$(cat "$CERT_CALLS")" == *'get certificates.cert-manager.io'* ]]; then
      ok "$resource $mode keeps checking the remaining source"
    else
      err "$resource $mode stopped early: $(cat "$CERT_CALLS")"
    fi
  done
done
reset_fixtures
export CERT_SECRETS=expiring CERT_FAIL_RESOURCE=certificates
run_cert --cert-manager
assert_contains 'findings survive a later failed query' 'EXPIRING in 12d'
assert_rc 'query failure takes precedence over findings' 1 "$rc"
reset_fixtures
export CERT_FAIL_RESOURCE=secrets
run_cert
assert_contains 'a Forbidden on secrets names the permission' 'could not list TLS secrets (needs list permission on secrets)'

printf '\n--- Usage and environment ---\n'
for days in 0 abc -1 1.5; do
  run_cert --warn-days "$days"
  assert_rc "--warn-days $days -> 3" 3 "$rc"
done
bare_path="$(mktemp -d)"
ln -s "$BASH" "$bare_path/bash"
run_with_path "$bare_path"
assert_rc 'missing kubectl -> exit 2' 2 "$rc"
ln -s "$scratch/kbin/kubectl" "$bare_path/kubectl"
ln -s "$(command -v python3)" "$bare_path/python3"
run_with_path "$bare_path"
assert_rc 'missing openssl -> exit 2' 2 "$rc"
assert_contains 'missing openssl is named' 'openssl is not installed'
rm -rf "$bare_path"

printf '\n--- The private key never leaves the cluster listing ---\n'
if [[ ! -s "$ALL_OUT" || ! -s "$CERT_OPENSSL_CALLS" ]]; then
  err 'no output or openssl call was recorded; the key checks would pass vacuously'
else
  for needle in PRIVATE-KEY-CANARY "$KEY_B64" "${KEY_B64:0:24}"; do
    if grep -qF -- "$needle" "$ALL_OUT" "$CERT_OPENSSL_CALLS"; then
      err "key material reached the output or openssl: ${needle:0:24}"
    else
      ok "key material absent from every output and openssl input (${needle:0:12}...)"
    fi
  done
fi
if grep -v '^openssl x509 -noout -enddate$' "$CERT_OPENSSL_CALLS" | grep -q '^openssl '; then
  err "openssl was asked for something other than the end date: $(grep '^openssl ' "$CERT_OPENSSL_CALLS" | sort -u)"
else
  ok 'openssl only ever parsed a certificate from stdin'
fi
if grep -Evq '^(--context [^ ]+ )?(get|cluster-info)( |$)' "$ALL_CALLS"; then
  err "a kubectl verb other than get/cluster-info ran: $(grep -Ev '^(--context [^ ]+ )?(get|cluster-info)( |$)' "$ALL_CALLS" | head -3)"
else
  ok 'only get and cluster-info were ever executed'
fi

printf '\n--- A real certificate, when openssl is installed ---\n'
if command -v openssl >/dev/null 2>&1 &&
   openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=fixture.invalid \
     -keyout "$scratch/real.key" -out "$scratch/real.crt" >/dev/null 2>&1 &&
   python3 - "$scratch" <<'PY'
import base64, json, pathlib, sys
root=pathlib.Path(sys.argv[1])
b64=lambda name: base64.b64encode((root/name).read_bytes()).decode()
secret={'metadata':{'namespace':'demo','name':'real-tls'},'type':'kubernetes.io/tls',
        'data':{'tls.crt':b64('real.crt'),'tls.key':b64('real.key')}}
(root/'real.json').write_text(json.dumps({'items':[secret]}))
PY
then
  reset_fixtures
  export CERT_SECRETS=real
  # The real openssl, not the stub: only the kubectl stub is put ahead of PATH.
  run_with_path "$scratch/kbin:$PATH" --warn-days 30
  assert_rc 'a one-day certificate parsed by the real openssl -> findings exit 0' 0 "$rc"
  assert_contains 'the real end date is read' 'secret demo/real-tls: EXPIRING in 0d ('
else
  ok 'openssl is not installed (or could not mint a certificate); real-certificate check skipped'
fi

printf '\nCertificate expiry failures: %s\n' "$failures"
(( failures == 0 ))
