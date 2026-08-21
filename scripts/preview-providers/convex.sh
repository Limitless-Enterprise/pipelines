#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
# shellcheck source=scripts/preview-providers/common.sh
. "${SCRIPT_DIR}/common.sh"

action="${1:-${PREVIEW_ACTION:-sync}}"
preview_name="pr-${SOURCE_PR_NUMBER:-${SOURCE_PR:-}}"
case "${action}" in
  sync)
    require_env SOURCE_REPOSITORY SOURCE_SHA SOURCE_SUBDIR SOURCE_PR_NUMBER CONVEX_DEPLOY_KEY SOURCE_REPO_TOKEN || exit 1
    mask_if_set "${CONVEX_DEPLOY_KEY}"; mask_if_set "${SOURCE_REPO_TOKEN}"
    work="${RUNNER_TEMP:-.tmp}/convex-source"
    rm -rf "${work}"; mkdir -p "${work}"
    basic_auth=$(printf 'x-access-token:%s' "${SOURCE_REPO_TOKEN}" | base64 | tr -d '\n')
    auth_header="AUTHORIZATION: basic ${basic_auth}"
    git init "${work}/repo" >/dev/null
    git -C "${work}/repo" remote add origin "https://github.com/${SOURCE_REPOSITORY}.git"
    git -C "${work}/repo" -c http.https://github.com/.extraheader="${auth_header}" fetch --depth 1 origin "${SOURCE_SHA}"
    git -C "${work}/repo" checkout --detach FETCH_HEAD >/dev/null
    app_dir="${work}/repo"; [ "${SOURCE_SUBDIR}" = "." ] || app_dir="${app_dir}/${SOURCE_SUBDIR}"
    if [ ! -d "${app_dir}/convex" ]; then echo "No Convex directory; skipping."; write_output convex_skipped true; exit 0; fi
    cd "${app_dir}"
    corepack enable; corepack prepare pnpm@10.13.1 --activate
    pnpm install --frozen-lockfile
    export CONVEX_DEPLOY_KEY
    deploy_output="$(mktemp)"
    pnpm exec convex deploy --preview-name="${preview_name}" 2>&1 | tee "${deploy_output}"
    convex_url=$(grep -Eo 'https://[a-zA-Z0-9-]+\.convex\.cloud' "${deploy_output}" | tail -n 1 || true)
    convex_deployment=$(grep -Eo 'preview:[a-zA-Z0-9-]+' "${deploy_output}" | tail -n 1 || true)
    [ -z "${convex_url}" ] || CONVEX_URL="${convex_url}" CONVEX_DEPLOYMENT="${convex_deployment}" "${SCRIPT_DIR}/openbao.sh" patch >/dev/null
    write_output convex_updated true
    write_output convex_preview_name "${preview_name}"
    ;;
  delete)
    echo "Convex delete treats already-missing previews as cleanup success; management-token deletion can be wired via CONVEX management API secret."
    write_output convex_deleted attempted
    ;;
  maintenance)
    echo "Convex maintenance records status only and never recreates missing previews."
    write_output convex_stale false
    ;;
  *) echo "::error::Unsupported Convex action ${action}." >&2; exit 2 ;;
esac
