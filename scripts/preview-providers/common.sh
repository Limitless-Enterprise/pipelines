#!/usr/bin/env bash
set -euo pipefail

mask_if_set() {
  local value="${1:-}"
  [ -z "${value}" ] || echo "::add-mask::${value}"
}

require_env() {
  local missing=0 key
  for key in "$@"; do
    if [ -z "${!key:-}" ]; then
      echo "::error::${key} is required." >&2
      missing=1
    fi
  done
  [ "${missing}" -eq 0 ]
}

retry_curl() {
  local attempt delay body_file status curl_exit
  delay="${RETRY_CURL_INITIAL_DELAY:-2}"
  body_file="$(mktemp)"
  for attempt in 1 2 3 4 5; do
    set +e
    status=$(curl --silent --show-error --output "${body_file}" --write-out "%{http_code}" "$@")
    curl_exit=$?
    set -e
    if [ "${curl_exit}" -eq 0 ] && [ "${status}" -ge 200 ] && [ "${status}" -lt 400 ]; then
      cat "${body_file}"
      rm -f "${body_file}"
      return 0
    fi
    if [ "${status}" -ge 400 ] && [ "${status}" -lt 500 ]; then
      echo "Request failed with non-retryable HTTP ${status}." >&2
      jq -r '.errors? // .error? // .message? // .' "${body_file}" >&2 2>/dev/null || cat "${body_file}" >&2 || true
      rm -f "${body_file}"
      return 1
    fi
    if [ "${attempt}" -eq 5 ]; then
      echo "Request failed after ${attempt} attempts (HTTP ${status}, curl exit ${curl_exit})." >&2
      jq -r '.errors? // .error? // .message? // .' "${body_file}" >&2 2>/dev/null || cat "${body_file}" >&2 || true
      rm -f "${body_file}"
      return 1
    fi
    echo "Request failed on attempt ${attempt} (HTTP ${status}, curl exit ${curl_exit}); retrying in ${delay}s." >&2
    sleep "${delay}"
    delay=$((delay * 2))
  done
}

mint_openbao_token() {
  require_env OPENBAO_ADDR || exit 1
  local auth_path="${OPENBAO_AUTH_PATH:-jwt}"
  local audience="${OPENBAO_AUDIENCE:-openbao}"
  local role="${OPENBAO_ROLE:-github-actions-railway-deployments-preview-integrations}"
  local oidc_response oidc_jwt login_payload openbao_token
  if [ -n "${OPENBAO_TOKEN:-}" ]; then
    mask_if_set "${OPENBAO_TOKEN}"
    printf '%s' "${OPENBAO_TOKEN}"
    return 0
  fi
  require_env ACTIONS_ID_TOKEN_REQUEST_TOKEN ACTIONS_ID_TOKEN_REQUEST_URL || exit 1
  oidc_response=$(retry_curl --get --header "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" --data-urlencode "audience=${audience}" "${ACTIONS_ID_TOKEN_REQUEST_URL}")
  oidc_jwt=$(jq -r '.value // empty' <<<"${oidc_response}")
  if [ -z "${oidc_jwt}" ]; then
    echo "::error::GitHub did not return an OIDC token." >&2
    exit 1
  fi
  login_payload=$(jq -n --arg role "${role}" --arg jwt "${oidc_jwt}" '{role: $role, jwt: $jwt}')
  openbao_token=$(retry_curl --request POST --header "Content-Type: application/json" --data "${login_payload}" "${OPENBAO_ADDR%/}/v1/auth/${auth_path}/login" | jq -r '.auth.client_token // empty')
  if [ -z "${openbao_token}" ]; then
    echo "::error::OpenBao login did not return a client token." >&2
    exit 1
  fi
  mask_if_set "${openbao_token}"
  printf '%s' "${openbao_token}"
}

kv_data_url() {
  local mount="$1" path="$2"
  printf '%s/v1/%s/data/%s' "${OPENBAO_ADDR%/}" "${mount}" "${path}"
}

kv_metadata_url() {
  local mount="$1" path="$2"
  printf '%s/v1/%s/metadata/%s' "${OPENBAO_ADDR%/}" "${mount}" "${path}"
}

openbao_read_data() {
  local token="$1" mount="$2" path="$3"
  retry_curl --header "X-Vault-Token: ${token}" "$(kv_data_url "${mount}" "${path}")"
}

openbao_write_data() {
  local token="$1" mount="$2" path="$3" data_json="$4"
  retry_curl --request POST --header "X-Vault-Token: ${token}" --header "Content-Type: application/json" --data "$(jq -cn --argjson data "${data_json}" '{data:$data}')" "$(kv_data_url "${mount}" "${path}")" >/dev/null
}

openbao_delete_metadata() {
  local token="$1" mount="$2" path="$3"
  retry_curl --request DELETE --header "X-Vault-Token: ${token}" "$(kv_metadata_url "${mount}" "${path}")" >/dev/null || true
}

write_output() {
  local key="$1" value="$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "${key}" "${value}" >> "${GITHUB_OUTPUT}"
  fi
  printf '%s=%s\n' "${key}" "${value}"
}
