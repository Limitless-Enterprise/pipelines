#!/usr/bin/env bash
set -euo pipefail

: "${DEPLOYMENTS_REPO:?DEPLOYMENTS_REPO is required}"
: "${DEPLOYMENTS_SERVICE:?DEPLOYMENTS_SERVICE is required}"
: "${DEPLOYMENTS_REPO_TOKEN:?DEPLOYMENTS_REPO_TOKEN is required}"
: "${SOURCE_PR_NUMBER:?SOURCE_PR_NUMBER is required}"

preview_branch="preview/${DEPLOYMENTS_SERVICE}/${SOURCE_PR_NUMBER}"
export GH_TOKEN="${DEPLOYMENTS_REPO_TOKEN}"
repo_owner="${DEPLOYMENTS_REPO%%/*}"

existing_pr_number=$(gh api "repos/${DEPLOYMENTS_REPO}/pulls?head=${repo_owner}:${preview_branch}&state=open" --jq '.[0].number // empty')
if [ -z "${existing_pr_number}" ]; then
  echo "No open deployment preview PR found for ${preview_branch}."
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
