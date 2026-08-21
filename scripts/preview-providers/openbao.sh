#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
# shellcheck source=scripts/preview-providers/common.sh
. "${SCRIPT_DIR}/common.sh"

action="${1:-${PREVIEW_ACTION:-ensure}}"
require_env OPENBAO_ADDR OPENBAO_KV_MOUNT OPENBAO_PR_SHARED_PATH OPENBAO_PR_SERVICE_PATH || exit 1
token="$(mint_openbao_token)"

json_data() { jq -c '.data.data // empty'; }

case "${action}" in
  ensure)
    require_env OPENBAO_TEMPLATE_SHARED_PATH OPENBAO_TEMPLATE_SERVICE_PATH IS_FIRST_OPEN || exit 1
    if [ "${IS_FIRST_OPEN}" = "true" ]; then
      shared_template=$(openbao_read_data "${token}" "${OPENBAO_KV_MOUNT}" "${OPENBAO_TEMPLATE_SHARED_PATH}" | json_data)
      service_template=$(openbao_read_data "${token}" "${OPENBAO_KV_MOUNT}" "${OPENBAO_TEMPLATE_SERVICE_PATH}" | json_data)
      if [ -z "${shared_template}" ] || [ "${shared_template}" = "null" ] || [ -z "${service_template}" ] || [ "${service_template}" = "null" ]; then
        echo "::error::OpenBao PR templates are missing; refusing to invent defaults." >&2
        exit 1
      fi
      openbao_write_data "${token}" "${OPENBAO_KV_MOUNT}" "${OPENBAO_PR_SHARED_PATH}" "${shared_template}"
      openbao_write_data "${token}" "${OPENBAO_KV_MOUNT}" "${OPENBAO_PR_SERVICE_PATH}" "${service_template}"
      write_output config_created true
      write_output config_changed true
      echo "OpenBao PR config created from templates at configured shared/service paths."
    else
      openbao_read_data "${token}" "${OPENBAO_KV_MOUNT}" "${OPENBAO_PR_SHARED_PATH}" >/dev/null
      openbao_read_data "${token}" "${OPENBAO_KV_MOUNT}" "${OPENBAO_PR_SERVICE_PATH}" >/dev/null
      write_output config_created false
      write_output config_changed false
      echo "OpenBao PR config exists; update path did not recopy templates."
    fi
    write_output openbao_config_exists true
    ;;
  patch)
    existing=$(openbao_read_data "${token}" "${OPENBAO_KV_MOUNT}" "${OPENBAO_PR_SERVICE_PATH}" | json_data)
    if [ -z "${existing}" ] || [ "${existing}" = "null" ]; then
      echo "::error::OpenBao service PR config is missing; cannot patch runtime fields." >&2
      exit 1
    fi
    patch='{}'
    if [ -n "${DATABASE_URL:-}" ]; then
      mask_if_set "${DATABASE_URL}"
      patch=$(jq -cn --argjson p "${patch}" --arg v "${DATABASE_URL}" '$p + {DATABASE_URL:$v, POSTGRES_URL:$v, DIRECT_DATABASE_URL:$v}')
    fi
    [ -z "${CONVEX_URL:-}" ] || patch=$(jq -cn --argjson p "${patch}" --arg v "${CONVEX_URL}" '$p + {NEXT_PUBLIC_CONVEX_URL:$v, CONVEX_URL:$v}')
    [ -z "${CONVEX_DEPLOYMENT:-}" ] || patch=$(jq -cn --argjson p "${patch}" --arg v "${CONVEX_DEPLOYMENT}" '$p + {CONVEX_DEPLOYMENT:$v}')
    if [ -n "${CONVEX_DEPLOY_KEY:-}" ]; then
      mask_if_set "${CONVEX_DEPLOY_KEY}"
      patch=$(jq -cn --argjson p "${patch}" --arg v "${CONVEX_DEPLOY_KEY}" '$p + {CONVEX_DEPLOY_KEY:$v}')
    fi
    if [ "${patch}" = "{}" ]; then
      write_output config_changed false
      echo "No OpenBao runtime fields changed."
      exit 0
    fi
    merged=$(jq -cn --argjson old "${existing}" --argjson patch "${patch}" '$old + $patch')
    openbao_write_data "${token}" "${OPENBAO_KV_MOUNT}" "${OPENBAO_PR_SERVICE_PATH}" "${merged}"
    write_output config_changed true
    echo "OpenBao service PR config patched with changed runtime field names only."
    ;;
  delete)
    openbao_delete_metadata "${token}" "${OPENBAO_KV_MOUNT}" "${OPENBAO_PR_SERVICE_PATH}"
    openbao_delete_metadata "${token}" "${OPENBAO_KV_MOUNT}" "${OPENBAO_PR_SHARED_PATH}"
    write_output config_deleted true
    echo "OpenBao PR shared/service config paths deleted or already absent."
    ;;
  *) echo "::error::Unsupported OpenBao preview action ${action}." >&2; exit 2 ;;
esac
