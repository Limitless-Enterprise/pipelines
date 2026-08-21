#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
# shellcheck source=scripts/preview-providers/common.sh
. "${SCRIPT_DIR}/common.sh"

action="${1:-${PREVIEW_ACTION:-ensure-and-apply-schema}}"
require_env NEON_PROJECT_ID NEON_BRANCH_NAME || exit 1
if [ -z "${NEON_API_KEY:-}" ]; then
  token="$(mint_openbao_token)"
  require_env NEON_SECRET_PATH OPENBAO_ADDR || exit 1
  NEON_API_KEY=$(openbao_read_data "${token}" "${OPENBAO_KV_MOUNT:-platform-secrets}" "${NEON_SECRET_PATH}" | jq -r '.data.data.NEON_API_KEY // empty')
fi
require_env NEON_API_KEY || exit 1
mask_if_set "${NEON_API_KEY}"
api="https://console.neon.tech/api/v2/projects/${NEON_PROJECT_ID}"
branch_json() { retry_curl --header "Authorization: Bearer ${NEON_API_KEY}" "${api}/branches"; }
branch_id_for_name() { jq -r --arg name "${NEON_BRANCH_NAME}" '.branches[]? | select(.name==$name) | .id' | head -n 1; }
connection_uri_for_branch() {
  local branch_id="$1"
  if [ -z "${NEON_DATABASE_NAME:-}" ] || [ -z "${NEON_ROLE_NAME:-}" ]; then
    return 0
  fi
  retry_curl \
    --request POST \
    --header "Authorization: Bearer ${NEON_API_KEY}" \
    --header "Content-Type: application/json" \
    --data "$(jq -cn --arg branch_id "${branch_id}" --arg database_name "${NEON_DATABASE_NAME}" --arg role_name "${NEON_ROLE_NAME}" '{branch_id:$branch_id,database_name:$database_name,role_name:$role_name}')" \
    "${api}/connection_uri" | jq -r '.uri // .connection_uri // empty'
}
case "${action}" in
  ensure-and-apply-schema)
    branch_id=$(branch_json | branch_id_for_name || true)
    created=false
    if [ -z "${branch_id}" ]; then
      payload=$(jq -cn --arg name "${NEON_BRANCH_NAME}" --arg exp "$(date -u --date '+14 days' +'%Y-%m-%dT%H:%M:%SZ')" '{branch:{name:$name,expires_at:$exp}}')
      created_json=$(retry_curl --request POST --header "Authorization: Bearer ${NEON_API_KEY}" --header "Content-Type: application/json" --data "${payload}" "${api}/branches")
      branch_id=$(jq -r '.branch.id // empty' <<<"${created_json}")
      DATABASE_URL=$(jq -r '.connection_uris[0].connection_uri // .connection_uri // empty' <<<"${created_json}")
      [ -z "${DATABASE_URL}" ] || mask_if_set "${DATABASE_URL}"
      created=true
      if [ -n "${DATABASE_URL}" ]; then
        PREVIEW_ACTION=patch DATABASE_URL="${DATABASE_URL}" "${SCRIPT_DIR}/openbao.sh" patch >/dev/null
      fi
    fi
    if [ -z "${NEON_PR_DATABASE_URL:-${DATABASE_URL:-}}" ] && [ -n "${branch_id}" ]; then
      DATABASE_URL=$(connection_uri_for_branch "${branch_id}" || true)
      [ -z "${DATABASE_URL}" ] || mask_if_set "${DATABASE_URL}"
      if [ "${created}" = "true" ] && [ -n "${DATABASE_URL}" ]; then
        PREVIEW_ACTION=patch DATABASE_URL="${DATABASE_URL}" "${SCRIPT_DIR}/openbao.sh" patch >/dev/null
      fi
    fi
    write_output neon_created "${created}"
    write_output neon_recreated "${created}"
    write_output neon_branch_id "${branch_id}"
    if [ -n "${NEON_PR_DATABASE_URL:-${DATABASE_URL:-}}" ]; then
      export NEON_PR_DATABASE_URL="${NEON_PR_DATABASE_URL:-${DATABASE_URL}}"
      if [ -n "${NEON_SCHEMA_COMMAND:-}" ]; then
        bash -c "${NEON_SCHEMA_COMMAND}"
      else
        echo "No NEON_SCHEMA_COMMAND configured; skipping schema application."
      fi
      write_output schema_applied true
    else
      write_output schema_applied false
      echo "Neon branch is present but no database URL was available for schema application."
    fi
    ;;
  delete)
    branch_id=$(branch_json | branch_id_for_name || true)
    if [ -z "${branch_id}" ]; then echo "Neon branch already absent: ${NEON_BRANCH_NAME}."; write_output neon_deleted false; exit 0; fi
    retry_curl --request DELETE --header "Authorization: Bearer ${NEON_API_KEY}" "${api}/branches/${branch_id}" >/dev/null
    write_output neon_deleted true
    echo "Deleted Neon preview branch ${NEON_BRANCH_NAME}."
    ;;
  maintenance)
    branch_id=$(branch_json | branch_id_for_name || true)
    if [ -z "${branch_id}" ]; then echo "Neon branch missing; maintenance will not recreate it."; write_output neon_stale true; exit 0; fi
    if [ "${NEON_EXTEND_BEFORE_EXPIRY:-true}" = "true" ]; then
      payload=$(jq -cn --arg exp "$(date -u --date '+14 days' +'%Y-%m-%dT%H:%M:%SZ')" '{branch:{expires_at:$exp}}')
      retry_curl --request PATCH --header "Authorization: Bearer ${NEON_API_KEY}" --header "Content-Type: application/json" --data "${payload}" "${api}/branches/${branch_id}" >/dev/null
      write_output neon_extended true
    fi
    write_output neon_stale false
    write_output neon_branch_id "${branch_id}"
    echo "Neon branch exists; maintenance did not recreate resources."
    ;;
  *) echo "::error::Unsupported Neon action ${action}." >&2; exit 2 ;;
esac
