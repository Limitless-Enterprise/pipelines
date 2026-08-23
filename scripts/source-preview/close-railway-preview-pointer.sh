#!/usr/bin/env bash
set -euo pipefail

: "${DEPLOYMENTS_REPO:?DEPLOYMENTS_REPO is required}"
: "${DEPLOYMENTS_SERVICE:?DEPLOYMENTS_SERVICE is required}"
: "${DEPLOYMENTS_REPO_TOKEN:?DEPLOYMENTS_REPO_TOKEN is required}"
: "${SOURCE_PR_NUMBER:?SOURCE_PR_NUMBER is required}"

preview_branch="preview/${DEPLOYMENTS_SERVICE}/${SOURCE_PR_NUMBER}"
export GH_TOKEN="${DEPLOYMENTS_REPO_TOKEN}"
# Force gh to use the OpenBao-minted railway-deployments installation token.
# Some callers export GITHUB_TOKEN for the source repository; that token cannot
# read or close pull requests in the deployment repository and fails with 403.
unset GITHUB_TOKEN
repo_owner="${DEPLOYMENTS_REPO%%/*}"

lookup_open_preview_pr() {
  gh api "repos/${DEPLOYMENTS_REPO}/pulls?head=${repo_owner}:${preview_branch}&state=open" --jq '.[0].number // empty'
}

lookup_attempts="${CLOSE_POINTER_LOOKUP_ATTEMPTS:-6}"
lookup_sleep_seconds="${CLOSE_POINTER_LOOKUP_SLEEP_SECONDS:-10}"
existing_pr_number=""
for attempt in $(seq 1 "${lookup_attempts}"); do
  existing_pr_number=$(lookup_open_preview_pr)
  if [ -n "${existing_pr_number}" ]; then
    break
  fi
  if [ "${attempt}" -lt "${lookup_attempts}" ]; then
    echo "No open deployment preview PR found for ${preview_branch} on attempt ${attempt}/${lookup_attempts}; retrying in ${lookup_sleep_seconds}s."
    sleep "${lookup_sleep_seconds}"
  fi
done

if [ -z "${existing_pr_number}" ]; then
  echo "No open deployment preview PR found for ${preview_branch} after ${lookup_attempts} lookup attempts."
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf 'deployment_pr_url=\n' >> "${GITHUB_OUTPUT}"
  fi
  exit 0
fi

deployment_pr_url=$(gh api "repos/${DEPLOYMENTS_REPO}/pulls/${existing_pr_number}" --jq .html_url)
comment_body="Closing deployment preview because source PR #${SOURCE_PR_NUMBER} was closed. Railway/Neon/Convex/OpenBao preview cleanup is owned by railway-deployments PR lifecycle automation."
# Close first so cleanup does not depend on a best-effort explanatory comment.
jq -n '{state: "closed"}' \
  | gh api "repos/${DEPLOYMENTS_REPO}/pulls/${existing_pr_number}" --method PATCH --input - >/dev/null
jq -n --arg body "${comment_body}" '{body: $body}' \
  | gh api "repos/${DEPLOYMENTS_REPO}/issues/${existing_pr_number}/comments" --method POST --input - >/dev/null || \
  echo "Warning: failed to post close comment for deployment preview PR #${existing_pr_number}." >&2

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'deployment_pr_url=%s\n' "${deployment_pr_url}" >> "${GITHUB_OUTPUT}"
fi

echo "Closed deployment preview PR #${existing_pr_number} for ${preview_branch}: ${deployment_pr_url}"
