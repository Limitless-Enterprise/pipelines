#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_EVENT_NAME:?GITHUB_EVENT_NAME is required}"
: "${GITHUB_EVENT_PATH:?GITHUB_EVENT_PATH is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"

QUALITY_WORKFLOW_FILE="${QUALITY_WORKFLOW_FILE:-app-pr-quality.yml}"

emit() {
  local key="$1" value="$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
  fi
  printf '%s=%s\n' "$key" "$value"
}

skip() {
  emit should_publish false
  emit skip_reason "$1"
  exit 0
}

require_quality_success_for_sha() {
  local pr_number="$1" head_ref="$2" head_sha="$3"
  local encoded_head_ref runs_json
  encoded_head_ref=$(jq -nr --arg v "$head_ref" '$v|@uri')
  runs_json=$(gh api "repos/${GITHUB_REPOSITORY}/actions/workflows/${QUALITY_WORKFLOW_FILE}/runs?branch=${encoded_head_ref}&event=pull_request&status=success&per_page=50")
  if jq -e --arg sha "$head_sha" '.workflow_runs[]? | select(.head_sha == $sha and .conclusion == "success")' <<<"${runs_json}" >/dev/null; then
    return 0
  fi
  echo "::error::No successful ${QUALITY_WORKFLOW_FILE} run was found for source PR #${pr_number} current head SHA ${head_sha}."
  return 1
}

workflow_head_sha=""
source_pr_number=""

case "${GITHUB_EVENT_NAME}" in
  workflow_run)
    workflow_name=$(jq -r '.workflow_run.name // empty' "${GITHUB_EVENT_PATH}")
    conclusion=$(jq -r '.workflow_run.conclusion // empty' "${GITHUB_EVENT_PATH}")
    workflow_head_sha=$(jq -r '.workflow_run.head_sha // empty' "${GITHUB_EVENT_PATH}")
    if [ "${workflow_name}" != "App PR Quality" ]; then
      skip "Workflow run '${workflow_name}' is not App PR Quality."
    fi
    if [ "${conclusion}" != "success" ]; then
      skip "App PR Quality concluded '${conclusion}', so no preview pointer will be published."
    fi
    source_pr_number=$(jq -r '.workflow_run.pull_requests[0].number // empty' "${GITHUB_EVENT_PATH}")
    if [ -z "${source_pr_number}" ] || [ "${source_pr_number}" = "null" ]; then
      skip "App PR Quality run was not associated with a pull request; push/manual quality runs do not publish preview pointers."
    fi
    ;;
  workflow_dispatch)
    source_pr_number="${SOURCE_PR_INPUT:-}"
    if [ -z "${source_pr_number}" ]; then
      echo "::error::workflow_dispatch requires source_pr."
      exit 1
    fi
    ;;
  *)
    skip "Unsupported event '${GITHUB_EVENT_NAME}'."
    ;;
esac

pr_json=$(gh api "repos/${GITHUB_REPOSITORY}/pulls/${source_pr_number}")
source_pr_url=$(jq -r '.html_url' <<<"${pr_json}")
source_base=$(jq -r '.base.ref' <<<"${pr_json}")
source_head=$(jq -r '.head.ref' <<<"${pr_json}")
source_sha=$(jq -r '.head.sha' <<<"${pr_json}")
source_repo_full_name=$(jq -r '.head.repo.full_name' <<<"${pr_json}")
source_ref="refs/pull/${source_pr_number}/head"
draft=$(jq -r '.draft' <<<"${pr_json}")
state=$(jq -r '.state' <<<"${pr_json}")

if [ "${state}" != "open" ]; then
  skip "Source PR #${source_pr_number} is not open (${state}); no preview pointer will be published."
fi
if [ "${source_repo_full_name}" != "${GITHUB_REPOSITORY}" ]; then
  echo "::error::Fork or cross-repository source PRs are not supported for preview pointers. Source head repo: ${source_repo_full_name}."
  exit 1
fi
if [ "${draft}" = "true" ]; then
  skip "Source PR #${source_pr_number} is a draft; previews start only after ready_for_review plus green App PR Quality."
fi
if [ -n "${workflow_head_sha}" ] && [ "${workflow_head_sha}" != "${source_sha}" ]; then
  skip "Successful App PR Quality SHA ${workflow_head_sha} is stale; current source PR head is ${source_sha}."
fi

case "${source_head}:${source_base}" in
  feature/*:release/*|fix/*:release/*)
    preview_kind="release-pr"
    ;;
  hotfix/*:main)
    preview_kind="hotfix-main-pr"
    ;;
  *)
    echo "::error::Invalid preview branch pairing: head '${source_head}' targets base '${source_base}'. Expected feature/* or fix/* -> release/*, and hotfix/* -> main."
    exit 1
    ;;
esac

if [ "${GITHUB_EVENT_NAME}" = "workflow_dispatch" ]; then
  require_quality_success_for_sha "${source_pr_number}" "${source_head}" "${source_sha}"
fi

emit should_publish true
emit skip_reason ""
emit source_pr_number "${source_pr_number}"
emit source_pr_url "${source_pr_url}"
emit source_base "${source_base}"
emit source_head "${source_head}"
emit source_sha "${source_sha}"
emit source_ref "${source_ref}"
emit preview_kind "${preview_kind}"
