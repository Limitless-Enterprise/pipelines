#!/usr/bin/env bash
set -euo pipefail

: "${DEPLOYMENTS_REPO:?DEPLOYMENTS_REPO is required}"
: "${DEPLOYMENTS_PROJECT:?DEPLOYMENTS_PROJECT is required}"
: "${DEPLOYMENTS_SERVICE:?DEPLOYMENTS_SERVICE is required}"
: "${SOURCE_REPOSITORY:?SOURCE_REPOSITORY is required}"
: "${SOURCE_SUBDIR:?SOURCE_SUBDIR is required}"
: "${DEPLOYMENTS_REPO_TOKEN:?DEPLOYMENTS_REPO_TOKEN is required}"
: "${SOURCE_PR_NUMBER:?SOURCE_PR_NUMBER is required}"
: "${SOURCE_PR_URL:?SOURCE_PR_URL is required}"
: "${SOURCE_PR_BASE:?SOURCE_PR_BASE is required}"
: "${SOURCE_PR_HEAD:?SOURCE_PR_HEAD is required}"
: "${SOURCE_SHA:?SOURCE_SHA is required}"
: "${SOURCE_REF:?SOURCE_REF is required}"
: "${PREVIEW_KIND:?PREVIEW_KIND is required}"

case "${SOURCE_PR_HEAD}:${SOURCE_PR_BASE}" in
  feature/*:release/*|fix/*:release/*|hotfix/*:main)
    ;;
  *)
    echo "::error::Refusing to publish preview pointer for invalid branch pairing '${SOURCE_PR_HEAD}' -> '${SOURCE_PR_BASE}'."
    exit 1
    ;;
esac

preview_branch="preview/${DEPLOYMENTS_SERVICE}/${SOURCE_PR_NUMBER}"
service_root="${DEPLOYMENTS_PROJECT}/${DEPLOYMENTS_SERVICE}"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

export GH_TOKEN="${DEPLOYMENTS_REPO_TOKEN}"

recheck_source_pr() {
  local phase="$1" pr_json current_state current_draft current_sha current_base current_head current_repo
  if [ -z "${SOURCE_RECHECK_TOKEN:-}" ]; then
    echo "::error::SOURCE_RECHECK_TOKEN is required to recheck source PR state before publishing deployment preview pointers."
    exit 1
  fi
  pr_json=$(GH_TOKEN="${SOURCE_RECHECK_TOKEN}" gh api "repos/${SOURCE_REPOSITORY}/pulls/${SOURCE_PR_NUMBER}")
  current_state=$(jq -r '.state' <<<"${pr_json}")
  current_draft=$(jq -r '.draft' <<<"${pr_json}")
  current_sha=$(jq -r '.head.sha' <<<"${pr_json}")
  current_base=$(jq -r '.base.ref' <<<"${pr_json}")
  current_head=$(jq -r '.head.ref' <<<"${pr_json}")
  current_repo=$(jq -r '.head.repo.full_name' <<<"${pr_json}")

  if [ "${current_state}" != "open" ]; then
    echo "::error::Source PR #${SOURCE_PR_NUMBER} is ${current_state} during ${phase}; refusing to publish preview pointer."
    exit 1
  fi
  if [ "${current_draft}" = "true" ]; then
    echo "::error::Source PR #${SOURCE_PR_NUMBER} is draft during ${phase}; refusing to publish preview pointer."
    exit 1
  fi
  if [ "${current_repo}" != "${SOURCE_REPOSITORY}" ]; then
    echo "::error::Source PR #${SOURCE_PR_NUMBER} head repo changed to ${current_repo} during ${phase}; expected ${SOURCE_REPOSITORY}."
    exit 1
  fi
  if [ "${current_sha}" != "${SOURCE_SHA}" ] || [ "${current_base}" != "${SOURCE_PR_BASE}" ] || [ "${current_head}" != "${SOURCE_PR_HEAD}" ]; then
    echo "::error::Source PR #${SOURCE_PR_NUMBER} changed during ${phase}; expected ${SOURCE_PR_HEAD}->${SOURCE_PR_BASE}@${SOURCE_SHA}, got ${current_head}->${current_base}@${current_sha}."
    exit 1
  fi
  echo "Source PR #${SOURCE_PR_NUMBER} rechecked during ${phase}: ${current_head}->${current_base}@${current_sha}."
}

git clone "https://x-access-token:${DEPLOYMENTS_REPO_TOKEN}@github.com/${DEPLOYMENTS_REPO}.git" "${workdir}/railway-deployments"
cd "${workdir}/railway-deployments"
git config user.name "railway-deploy-bot[bot]"
git config user.email "railway-deploy-bot[bot]@users.noreply.github.com"
git fetch origin main "${preview_branch}" || true
if git show-ref --verify --quiet "refs/remotes/origin/${preview_branch}"; then
  git checkout -B "${preview_branch}" "origin/${preview_branch}"
else
  git checkout -B "${preview_branch}" origin/main
fi

target="${service_root}"
mkdir -p "${target}"
recheck_source_pr "before-writing-pointer"
printf 'SOURCE_REPOSITORY=%s\nSOURCE_SHA=%s\nSOURCE_REF=%s\nSOURCE_SUBDIR=%s\nSOURCE_PR=%s\nSOURCE_PR_BASE=%s\nSOURCE_PR_URL=%s\nDEPLOYMENT_MODE=preview\nPREVIEW_KIND=%s\n' \
  "${SOURCE_REPOSITORY}" \
  "${SOURCE_SHA}" \
  "${SOURCE_REF}" \
  "${SOURCE_SUBDIR}" \
  "${SOURCE_PR_NUMBER}" \
  "${SOURCE_PR_BASE}" \
  "${SOURCE_PR_URL}" \
  "${PREVIEW_KIND}" \
  > "${target}/source.env"

jq -n \
  --arg repository "${SOURCE_REPOSITORY}" \
  --arg sha "${SOURCE_SHA}" \
  --arg ref "${SOURCE_REF}" \
  --arg source_subdir "${SOURCE_SUBDIR}" \
  --argjson source_pr "${SOURCE_PR_NUMBER}" \
  --arg source_pr_url "${SOURCE_PR_URL}" \
  --arg source_pr_base "${SOURCE_PR_BASE}" \
  --arg source_pr_head "${SOURCE_PR_HEAD}" \
  --arg deployment_mode "preview" \
  --arg preview_kind "${PREVIEW_KIND}" \
  --arg run_url "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-${SOURCE_REPOSITORY}}/actions/runs/${GITHUB_RUN_ID:-manual}" \
  --arg published_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{repository: $repository, sha: $sha, ref: $ref, source_subdir: $source_subdir, source_pr: $source_pr, source_pr_url: $source_pr_url, source_pr_base: $source_pr_base, source_pr_head: $source_pr_head, deployment_mode: $deployment_mode, preview_kind: $preview_kind, run_url: $run_url, published_at: $published_at}' \
  > "${target}/.source.json"

recheck_source_pr "after-writing-pointer"
git add "${target}/source.env" "${target}/.source.json"
if git diff --cached --quiet; then
  echo "No deployment preview pointer changes to publish."
else
  git commit -m "preview(${DEPLOYMENTS_PROJECT}/${DEPLOYMENTS_SERVICE}): source PR #${SOURCE_PR_NUMBER}"
  git push --set-upstream origin "${preview_branch}"
fi

body_file="${workdir}/deployment-pr-body.md"
cat > "${body_file}" <<EOF_BODY
## Preview source pointer

This PR was generated from an owned-code app source PR after \`App PR Quality\` succeeded for the same source head SHA. It is intended to trigger one temporary Railway PR environment for \`${DEPLOYMENTS_SERVICE}\` through the \`railway-deployments\` PR lifecycle.

Do not merge this PR as a production promotion. Close it when the source PR is closed or merged into its target branch.

## Source

- Source repo: \`${SOURCE_REPOSITORY}\`
- Source PR: ${SOURCE_PR_URL}
- Source base: \`${SOURCE_PR_BASE}\`
- Source head: \`${SOURCE_PR_HEAD}\`
- Source SHA: \`${SOURCE_SHA}\`
- Source subdir: \`${SOURCE_SUBDIR}\`
- Preview kind: \`${PREVIEW_KIND}\`

## Deployment pointer

- Service root: \`${service_root}\`
- Deployment branch: \`${preview_branch}\`
- Mode: \`preview\`

## Expected non-production automation

- Railway creates an ephemeral PR environment from this deployment-repo PR.
- Deployment-repo workflows prepare PR-scoped OpenBao config and provider previews.
- This source repository does not deploy directly and does not write provider secrets.
EOF_BODY

repo_owner="${DEPLOYMENTS_REPO%%/*}"
existing_pr_number=$(gh api "repos/${DEPLOYMENTS_REPO}/pulls?head=${repo_owner}:${preview_branch}&state=open" --jq '.[0].number // empty')
title="Preview ${DEPLOYMENTS_SERVICE} PR ${SOURCE_PR_NUMBER}"
if [ -n "${existing_pr_number}" ]; then
  jq -n --arg title "${title}" --arg body "$(cat "${body_file}")" '{title: $title, body: $body}' \
    | gh api "repos/${DEPLOYMENTS_REPO}/pulls/${existing_pr_number}" --method PATCH --input - >/dev/null
  deployment_pr_url=$(gh api "repos/${DEPLOYMENTS_REPO}/pulls/${existing_pr_number}" --jq .html_url)
else
  deployment_pr_url=$(jq -n \
    --arg title "${title}" \
    --arg head "${preview_branch}" \
    --arg base "main" \
    --arg body "$(cat "${body_file}")" \
    '{title: $title, head: $head, base: $base, body: $body}' \
    | gh api "repos/${DEPLOYMENTS_REPO}/pulls" --method POST --input - --jq .html_url)
fi

printf 'DEPLOYMENT_PR_URL=%s\n' "${deployment_pr_url}" >> "${GITHUB_ENV:-/dev/null}"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'deployment_pr_url=%s\n' "${deployment_pr_url}" >> "${GITHUB_OUTPUT}"
fi

echo "Deployment preview PR: ${deployment_pr_url}"
