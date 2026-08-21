#!/usr/bin/env bash
set -euo pipefail

if [ -z "${OPENBAO_ADDR:-}" ]; then
  echo "::error::OPENBAO_ADDR is required. Store Railway Deploy Bot GitHub App credentials in OpenBao."
  exit 1
fi
if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || [ -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
  echo "::error::GitHub OIDC is unavailable. Ensure permissions.id-token is write."
  exit 1
fi

repo_name="${GITHUB_REPOSITORY#*/}"
auth_path="${OPENBAO_AUTH_PATH:-jwt}"
audience="${OPENBAO_AUDIENCE:-openbao}"
role="${OPENBAO_ROLE:-github-actions-railway-deployments-${repo_name}}"
secret_path="${OPENBAO_SECRET_PATH:-secret/data/github-apps/railway-deploy-bot}"

retry_curl() {
  local attempt delay body_file status curl_exit
  delay=2
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
      echo "OpenBao/GitHub request failed with non-retryable HTTP ${status}." >&2
      rm -f "${body_file}"
      return 1
    fi
    if [ "${attempt}" -eq 5 ]; then
      echo "OpenBao/GitHub request failed after ${attempt} attempts; giving up." >&2
      rm -f "${body_file}"
      return 1
    fi
    echo "OpenBao/GitHub request failed on attempt ${attempt} (HTTP ${status}, curl exit ${curl_exit}); retrying in ${delay}s..." >&2
    sleep "${delay}"
    delay=$((delay * 2))
  done
}

oidc_response=$(retry_curl \
  --get \
  --header "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  --data-urlencode "audience=${audience}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}")
oidc_jwt=$(jq -r '.value // empty' <<<"${oidc_response}")
if [ -z "${oidc_jwt}" ]; then
  echo "::error::GitHub did not return an OIDC token."
  exit 1
fi

login_payload=$(jq -n --arg role "${role}" --arg jwt "${oidc_jwt}" '{role: $role, jwt: $jwt}')
openbao_token=$(retry_curl \
  --request POST \
  --header "Content-Type: application/json" \
  --data "${login_payload}" \
  "${OPENBAO_ADDR%/}/v1/auth/${auth_path}/login" | jq -r '.auth.client_token // empty')
if [ -z "${openbao_token}" ]; then
  echo "::error::OpenBao JWT login did not return a client token."
  exit 1
fi
echo "::add-mask::${openbao_token}"

secret_json=$(retry_curl \
  --header "X-Vault-Token: ${openbao_token}" \
  "${OPENBAO_ADDR%/}/v1/${secret_path}")

app_id=$(jq -r '.data.data.GITHUB_APP_ID // .data.data.APP_ID // empty' <<<"${secret_json}")
private_key=$(jq -r '.data.data.GITHUB_APP_PRIVATE_KEY // .data.data.PRIVATE_KEY // empty' <<<"${secret_json}")
installation_id=$(jq -r '.data.data.RAILWAY_DEPLOYMENTS_INSTALLATION_ID // .data.data.GITHUB_APP_INSTALLATION_ID // .data.data.INSTALLATION_ID // empty' <<<"${secret_json}")
if [ -z "${app_id}" ] || [ -z "${private_key}" ] || [ -z "${installation_id}" ]; then
  echo "::error::OpenBao secret must contain GITHUB_APP_ID, GITHUB_APP_PRIVATE_KEY, and RAILWAY_DEPLOYMENTS_INSTALLATION_ID."
  exit 1
fi

key_file="$(mktemp)"
trap 'rm -f "${key_file}"' EXIT
printf '%s\n' "${private_key}" > "${key_file}"
chmod 600 "${key_file}"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
now=$(date +%s)
iat=$((now - 60))
exp=$((now + 540))
header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
payload=$(jq -cn --argjson iat "${iat}" --argjson exp "${exp}" --arg iss "${app_id}" '{iat: $iat, exp: $exp, iss: $iss}' | b64url)
signature=$(printf '%s.%s' "${header}" "${payload}" | openssl dgst -sha256 -sign "${key_file}" -binary | b64url)
app_jwt="${header}.${payload}.${signature}"

deployments_token=$(retry_curl \
  --request POST \
  --header "Accept: application/vnd.github+json" \
  --header "Authorization: Bearer ${app_jwt}" \
  --header "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/app/installations/${installation_id}/access_tokens" | jq -r '.token // empty')
if [ -z "${deployments_token}" ]; then
  echo "::error::GitHub App installation token minting failed."
  exit 1
fi

echo "::add-mask::${deployments_token}"
if [ -z "${GITHUB_ENV:-}" ]; then
  echo "::error::GITHUB_ENV is unavailable."
  exit 1
fi
printf 'DEPLOYMENTS_REPO_TOKEN=%s\n' "${deployments_token}" >> "${GITHUB_ENV}"
