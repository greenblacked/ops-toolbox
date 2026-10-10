#!/usr/bin/env bash
# Decides whether a stage deploy is stale: stage already serves a commit that
# descends from (or is) this build's. Used twice by docs.yml, in the check-stage
# job and again at the start of the deploy job, because the second run of the
# check happens after the deploy job's concurrency group has released it.
#
# No Cloudflare token here, only the read-only GITHUB_TOKEN. Builds are per run
# and GitHub does not promise to start queued deploys in order, so an older
# master build can reach this point after a newer one deployed. Stage must
# never go back to older content. Anything else deploys, including a live
# version that cannot be read or compared. The tip of master is not used,
# because a push that touches no docs path moves it without starting a docs run.
#
# Environment: BASE_URL, SHA, REPO, GH_TOKEN, GITHUB_RUN_ID, GITHUB_OUTPUT.
# Writes stale=true|false to GITHUB_OUTPUT.
set -uo pipefail

stale=false
live="$(curl --silent --fail --max-time 10 "$BASE_URL/version.txt?run=$GITHUB_RUN_ID-$(date +%s)" 2>/dev/null || true)"
live="${live//[$'\r\n ']/}"
if [[ "$live" =~ ^[0-9a-f]{40}$ ]]; then
  status="$(gh api "repos/$REPO/compare/$SHA...$live" --jq .status 2>/dev/null || true)"
  if [ "$status" = "ahead" ] || [ "$status" = "identical" ]; then
    echo "::notice::stage already serves ${live:0:7}, which includes ${SHA:0:7}: skipping the stage deploy"
    stale=true
  fi
fi
echo "stale=$stale" >>"$GITHUB_OUTPUT"
