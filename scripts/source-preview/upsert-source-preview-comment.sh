#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${SOURCE_PR_NUMBER:?SOURCE_PR_NUMBER is required}"
: "${SOURCE_SHA:?SOURCE_SHA is required}"
: "${DEPLOYMENT_PR_URL:?DEPLOYMENT_PR_URL is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"

marker="<!-- railway-preview-pointer -->"
body_file="$(mktemp)"
trap 'rm -f "${body_file}"' EXIT
cat > "${body_file}" <<EOF_BODY
${marker}
Railway deployment preview PR: ${DEPLOYMENT_PR_URL}

Source SHA: \`${SOURCE_SHA}\`
Railway/Neon/Convex/OpenBao preview resources are owned by the linked \`railway-deployments\` PR lifecycle automation.
EOF_BODY

comment_id=$(gh api "repos/${GITHUB_REPOSITORY}/issues/${SOURCE_PR_NUMBER}/comments" --paginate \
  --jq 'map(select(.user.type == "Bot" and (.body // "" | contains("<!-- railway-preview-pointer -->")))) | last.id // empty')
if [ -n "${comment_id}" ]; then
  jq -n --arg body "$(cat "${body_file}")" '{body: $body}' \
    | gh api "repos/${GITHUB_REPOSITORY}/issues/comments/${comment_id}" --method PATCH --input - >/dev/null
else
  jq -n --arg body "$(cat "${body_file}")" '{body: $body}' \
    | gh api "repos/${GITHUB_REPOSITORY}/issues/${SOURCE_PR_NUMBER}/comments" --method POST --input - >/dev/null
fi
