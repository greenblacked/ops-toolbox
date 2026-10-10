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
# - version.txt answers 404, or an empty body: nothing is deployed yet (the
#   first deploy), the only case where an unknown live version means deploy.
# - version.txt is read and equals SHA, or the compare says the live commit is
#   ahead of or identical to SHA: stale, skip the deploy.
# - the compare says the live commit is behind or diverged: deploy.
# - anything else (network error, other HTTP status, a body that is not a
#   40-hex SHA, a compare that fails or does not know the live commit) after
#   the retries: an ::error:: and a non-zero exit. Nothing is deployed;
#   re-run the workflow later.
#
# The tip of master is not used, because a push that touches no docs path
# moves it without starting a docs run.
#
# Environment: BASE_URL, SHA, REPO, GH_TOKEN, GITHUB_RUN_ID, GITHUB_OUTPUT.
# Writes stale=true|false to GITHUB_OUTPUT.
set -euo pipefail

attempts=4
body="$(mktemp)"
trap 'rm -f "$body"' EXIT

fail() {
  echo "::error::stage freshness check failed: $1; nothing was deployed, re-run the workflow later"
  exit 1
}

# Retries with a growing pause between attempts.
backoff() {
  [ "$1" -lt "$attempts" ] && sleep $((2 * $1))
  return 0
}

code=""
for ((i = 1; i <= attempts; i++)); do
  code="$(curl --silent --max-time 10 --output "$body" --write-out '%{http_code}' \
    "$BASE_URL/version.txt?run=$GITHUB_RUN_ID-$(date +%s)" 2>/dev/null || true)"
  if [ "$code" = 200 ] || [ "$code" = 404 ]; then
    break
  fi
  echo "::warning::reading $BASE_URL/version.txt failed (HTTP ${code:-none}), attempt $i of $attempts"
  code=""
  backoff "$i"
done
[ -n "$code" ] || fail "could not read $BASE_URL/version.txt after $attempts attempts"

live=""
if [ "$code" = 200 ]; then
  live="$(tr -d '[:space:]' <"$body")"
fi

stale=false
if [ -z "$live" ]; then
  echo "::notice::stage serves no version yet: deploying"
elif ! [[ "$live" =~ ^[0-9a-f]{40}$ ]]; then
  fail "$BASE_URL/version.txt does not hold a commit SHA"
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
echo "stale=$stale" >>"$GITHUB_OUTPUT"
