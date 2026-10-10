# shellcheck shell=bash
# Decides whether a stage deploy is stale: stage already serves a commit that
# descends from (or is) this build's. Used twice by docs.yml, in the check-stage
# job and again at the start of the deploy job, because the second run of the
# check happens after the deploy job's concurrency group has released it.
#
# No Cloudflare token here, only the read-only GITHUB_TOKEN. Builds are per run
# and GitHub does not promise to start queued deploys in order, so an older
# master build can reach this point after a newer one deployed. Stage must
# never go back to older content, so the check fails closed:
#
# - version.txt answers HTTP 404 (curl itself exited 0): nothing is deployed
#   yet (the first deploy), the only case where an unknown live version means
#   deploy. An empty body is not that case.
# - the stage host does not resolve (curl exit 6) on every attempt AND a DNS
#   lookup confirms NXDOMAIN (the name does not exist, not a resolver
#   failure): stage cannot exist yet either. Observed: before the first
#   production deploy the stage hostname has no DNS record (the Custom Domain
#   and its preview wildcard appear with that deploy). A resolver failure that
#   recovers on a later attempt takes the normal path; SERVFAIL, a timeout or
#   a missing dig stay fail-closed. This is a clean skip, not a deploy: the
#   hostname cannot exist before production, the Worker itself may not exist
#   yet, and a preview with a smoke test that cannot pass only turns master
#   red. The next push to master after production deploys stage. For a
#   preview that does not exist on a resolving host no response is
#   documented, so that stays fail-closed too.
#   The skip also needs a persistent bootstrap-state check: GitHub has
#   recorded no successful production deployment. The deploy job enters the
#   "production" environment, so every production deploy leaves a deployment
#   there, and a run that fails (including a smoke test that failed and was
#   rolled back) ends with a failure or error status, never success. A
#   release tag cannot serve: release.yml pushes the tag BEFORE the production
#   deploy, so the stage run of the same push would see it while stage is
#   still NXDOMAIN and fail red on the first release. While no production
#   deployment has succeeded (none, or only queued, in progress, failed), the
#   skip applies. Once one has, DNS must exist: a later Cloudflare
#   misconfiguration that drops both the production Custom Domain and the
#   preview wildcard would otherwise green-skip every master run forever.
#   The deployments are read with the GitHub API (deployments?environment=
#   production, then each deployment's statuses; needs only deployments:
#   read), with a timeout and retries. The REST docs do not promise an order
#   for either list, so every deployment is walked until one has a status
#   with state success (a success is followed by inactive when a newer
#   deployment succeeds, so the newest status alone would miss it). If one
#   exists the check fails with an ::error:: about the missing Custom Domain /
#   preview wildcard; if a lookup fails it fails closed too.
# - version.txt is read and equals SHA, or the compare says the live commit is
#   ahead of or identical to SHA: stale, skip the deploy.
# - the compare says the live commit is behind or diverged: deploy.
# - anything else (a curl transfer error even after a 200 header, other HTTP
#   status, an empty body or one that is not a 40-hex SHA, a compare that fails or does not know the live commit) after
#   the retries: an ::error:: and a non-zero exit. Nothing is deployed;
#   re-run the workflow later.
#
# The tip of master is not used, because a push that touches no docs path
# moves it without starting a docs run.
#
# Environment: BASE_URL, SHA, REPO, GH_TOKEN, GITHUB_RUN_ID,
# GITHUB_OUTPUT.
# Writes to GITHUB_OUTPUT:
#   stale=true|false  stage already serves this build's commit or a newer one
#   skip=true|false   the stage deploy must not run: stale, or the stage host
#                     does not exist yet and production has no
#                     successful deployment either (then reason=no-stage-host, and a notice says to
#                     deploy production first). Callers gate on
#                     skip, a skipped deploy ends green.
set -euo pipefail

attempts=4
body="$(mktemp)"
trap 'rm -f "$body"' EXIT

fail() {
  echo "::error::stage freshness check failed: $1; nothing was deployed, re-run the workflow later"
  exit 1
}

# True only when a resolver answered and says the host ($1, a URL) does not
# exist. curl exit 6 alone cannot tell NXDOMAIN from SERVFAIL or a resolver
# outage. When it is not confirmed, dns_note says why, for the failure message.
dns_note=""
nxdomain() {
  local host="${1#*://}" out rc=0 st
  host="${host%%/*}"
  dns_note=""
  if ! command -v dig >/dev/null 2>&1; then
    dns_note="dig is not installed, so NXDOMAIN could not be confirmed"
    return 1
  fi
  out="$(timeout 15 dig +noall +comments "$host" A 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    dns_note="the DNS lookup for $host failed or timed out (dig exit $rc)"
    return 1
  fi
  if grep -q 'status: NXDOMAIN' <<<"$out"; then
    return 0
  fi
  st="$(grep -o 'status: [A-Z]*' <<<"$out" | head -n 1)"
  dns_note="the DNS lookup for $host answered '${st:-no status}', not NXDOMAIN"
  return 1
}

# Retries with a growing pause between attempts.
backoff() {
  [ "$1" -lt "$attempts" ] && sleep $((2 * $1))
  return 0
}

# curl's own exit status is kept apart from the HTTP code: a transfer that
# dies after a 200 header exits non-zero with http_code still 200 and a short
# or empty body, which must never read as "nothing deployed yet". The code is
# looked at only when curl exited 0, and only 200 and 404 end the retries.
code=""
live=""
unresolved=0
for ((i = 1; i <= attempts; i++)); do
  rc=0
  code="$(curl --silent --max-time 10 --output "$body" --write-out '%{http_code}' \
    "$BASE_URL/version.txt?run=$GITHUB_RUN_ID-$(date +%s)" 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    [ "$rc" -eq 6 ] && unresolved=$((unresolved + 1))
    echo "::warning::reading $BASE_URL/version.txt failed (curl exit $rc), attempt $i of $attempts"
  elif [ "$code" = 404 ]; then
    break
  elif [ "$code" = 200 ]; then
    live="$(tr -d '[:space:]' <"$body")"
    if [[ "$live" =~ ^[0-9a-f]{40}$ ]]; then
      break
    fi
    echo "::warning::$BASE_URL/version.txt answered 200 without a commit SHA, attempt $i of $attempts"
  else
    echo "::warning::reading $BASE_URL/version.txt failed (HTTP ${code:-none}), attempt $i of $attempts"
  fi
  code=""
  live=""
  backoff "$i"
done
if [ "$unresolved" -eq "$attempts" ] && nxdomain "$BASE_URL"; then
  host="${BASE_URL#*://}"
  host="${host%%/*}"
  # Bootstrap state: the skip is only right while production has never been
  # deployed successfully.
  prod_id=""
  prod_sha=""
  deployments=""
  deployments_ok=0
  for ((i = 1; i <= attempts; i++)); do
    if deployments="$(timeout 60 gh api "repos/$REPO/deployments?environment=production&per_page=100" --paginate --jq '.[] | "\(.id) \(.sha)"' 2>/dev/null)"; then
      deployments_ok=1
      break
    fi
    echo "::warning::listing the production deployments of $REPO failed, attempt $i of $attempts"
    backoff "$i"
  done
  [ "$deployments_ok" -eq 1 ] || fail "$host has no DNS record, but whether production was ever deployed could not be confirmed (listing the production deployments of $REPO failed after $attempts attempts)"
  while read -r id dsha; do
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    ok=0
    found=""
    for ((i = 1; i <= attempts; i++)); do
      if found="$(timeout 30 gh api "repos/$REPO/deployments/$id/statuses?per_page=100" --jq 'any(.[]; .state == "success")' 2>/dev/null)" && [[ "$found" == true || "$found" == false ]]; then
        ok=1
        break
      fi
      echo "::warning::reading the statuses of deployment $id failed, attempt $i of $attempts"
      backoff "$i"
    done
    [ "$ok" -eq 1 ] || fail "$host has no DNS record, but whether production was ever deployed could not be confirmed (reading the statuses of deployment $id failed after $attempts attempts)"
    if [ "$found" = true ]; then
      prod_id="$id"
      prod_sha="$dsha"
      break
    fi
  done <<<"$deployments"
  if [ -n "$prod_id" ]; then
    echo "::error::production was deployed (deployment $prod_id for ${prod_sha:0:7}) but $host has no DNS record: the Custom Domain or its preview wildcard is missing; check the Worker's Custom Domain / previews_enabled in Cloudflare; nothing was deployed"
    exit 1
  fi
  echo "::notice::stage does not exist yet (no DNS record for $host and no successful production deployment yet): skipped; deploy production first (release.yml or gh workflow run docs.yml --ref vX.Y.Z), then the next push to master deploys stage"
  {
    echo "stale=false"
    echo "skip=true"
    echo "reason=no-stage-host"
  } >>"$GITHUB_OUTPUT"
  exit 0
fi
if [ "$unresolved" -eq "$attempts" ] && [ -n "$dns_note" ]; then
  echo "::warning::the stage host did not resolve (curl exit 6) on every attempt, but $dns_note; failing closed"
fi
[ -n "$code" ] || fail "could not read a commit SHA from $BASE_URL/version.txt after $attempts attempts"

stale=false
if [ "$code" = 404 ]; then
  echo "::notice::stage serves no version yet: deploying"
elif [ "$live" = "$SHA" ]; then
  echo "::notice::stage already serves ${SHA:0:7}: skipping the stage deploy"
  stale=true
else
  status=""
  for ((i = 1; i <= attempts; i++)); do
    if status="$(timeout 30 gh api "repos/$REPO/compare/$SHA...$live" --jq .status 2>/dev/null)" && [ -n "$status" ]; then
      break
    fi
    status=""
    echo "::warning::comparing ${SHA:0:7} with ${live:0:7} failed, attempt $i of $attempts"
    backoff "$i"
  done
  case "$status" in
    ahead | identical)
      echo "::notice::stage already serves ${live:0:7}, which includes ${SHA:0:7}: skipping the stage deploy"
      stale=true
      ;;
    behind | diverged) ;;
    "") fail "could not compare ${SHA:0:7} with the live commit ${live:0:7} (unknown to $REPO?) after $attempts attempts" ;;
    *) fail "unexpected compare status '$status' for ${live:0:7}" ;;
  esac
fi
{
  echo "stale=$stale"
  echo "skip=$stale"
} >>"$GITHUB_OUTPUT"
