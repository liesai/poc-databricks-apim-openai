#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${TERRAFORM_DIR:-${ROOT_DIR}/terraform}"

NCC_NAME="${NCC_NAME:-poc-login-proxy-ncc}"
LOGIN_PROXY_DOMAIN="${LOGIN_PROXY_DOMAIN:-login.microsoftonline.com}"
ACCOUNTS_HOST="${DATABRICKS_ACCOUNTS_HOST:-https://accounts.azuredatabricks.net}"
POLL_SECONDS="${POLL_SECONDS:-20}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-1200}"

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

tf_output() {
  terraform -chdir="${TERRAFORM_DIR}" output -raw "$1"
}

account_api() {
  local method="$1"
  local path="$2"
  local body="${3:-}"

  local args=(
    -sS
    -X "${method}"
    -H "Authorization: Bearer ${DATABRICKS_TOKEN}"
    -H "Content-Type: application/json"
    -w $'\n%{http_code}'
  )

  if [[ -n "${body}" ]]; then
    args+=(--data "${body}")
  fi

  curl "${args[@]}" "${ACCOUNTS_HOST}${path}"
}

account_api_json() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local response
  local http_status
  local payload

  response="$(account_api "${method}" "${path}" "${body}")"
  http_status="$(tail -n 1 <<<"${response}")"
  payload="$(sed '$d' <<<"${response}")"

  if [[ "${http_status}" -lt 200 || "${http_status}" -ge 300 ]]; then
    echo "Databricks account API ${method} ${path} failed with HTTP ${http_status}." >&2
    echo "${payload}" >&2
    exit 1
  fi

  printf '%s\n' "${payload}"
}

require az
require curl
require jq
require terraform

if [[ -z "${DATABRICKS_ACCOUNT_ID:-}" ]]; then
  echo "Missing DATABRICKS_ACCOUNT_ID. Get it from the Azure Databricks account console." >&2
  exit 1
fi

if [[ -z "${LOGIN_PROXY_PRIVATE_LINK_SERVICE_ID:-}" ]]; then
  echo "Missing LOGIN_PROXY_PRIVATE_LINK_SERVICE_ID. Provide the Azure resource ID of the HAProxy Private Link Service." >&2
  exit 1
fi

RESOURCE_GROUP_NAME="$(tf_output resource_group_name)"
WORKSPACE_NAME="$(tf_output databricks_workspace_name)"
WORKSPACE_URL="$(tf_output databricks_workspace_url)"

WORKSPACE_LOCATION="$(az databricks workspace show \
  --resource-group "${RESOURCE_GROUP_NAME}" \
  --name "${WORKSPACE_NAME}" \
  --query location \
  -o tsv)"

WORKSPACE_ID="$(sed -E 's/^adb-([0-9]+)\..*/\1/' <<<"${WORKSPACE_URL}")"
if [[ -z "${WORKSPACE_ID}" || "${WORKSPACE_ID}" == "${WORKSPACE_URL}" ]]; then
  echo "Could not derive Databricks workspace ID from workspace URL '${WORKSPACE_URL}'." >&2
  exit 1
fi

DATABRICKS_TOKEN="$(az account get-access-token \
  --resource 2ff814a6-3304-4ab8-85cb-cd0e6f879c1d \
  --query accessToken \
  -o tsv)"

echo "Using Databricks account ${DATABRICKS_ACCOUNT_ID}."
echo "Workspace: ${WORKSPACE_NAME} (${WORKSPACE_ID}) in ${WORKSPACE_LOCATION}."
echo "Login proxy PLS: ${LOGIN_PROXY_PRIVATE_LINK_SERVICE_ID}."
echo "Domain routed through NCC: ${LOGIN_PROXY_DOMAIN}."

NCC_LIST="$(account_api_json GET "/api/2.0/accounts/${DATABRICKS_ACCOUNT_ID}/network-connectivity-configs")"
NCC_ID="$(jq -r --arg name "${NCC_NAME}" '.items[]? | select(.name == $name) | .network_connectivity_config_id // .id' <<<"${NCC_LIST}" | head -n 1)"

if [[ -z "${NCC_ID}" || "${NCC_ID}" == "null" ]]; then
  echo "Creating NCC '${NCC_NAME}'..."
  NCC="$(account_api_json POST "/api/2.0/accounts/${DATABRICKS_ACCOUNT_ID}/network-connectivity-configs" "$(jq -n \
    --arg name "${NCC_NAME}" \
    --arg region "${WORKSPACE_LOCATION}" \
    '{name: $name, region: $region}')")"
  NCC_ID="$(jq -r '.network_connectivity_config_id // .id' <<<"${NCC}")"
else
  echo "Reusing NCC '${NCC_NAME}' (${NCC_ID})."
fi

if [[ -z "${NCC_ID}" || "${NCC_ID}" == "null" ]]; then
  echo "Could not determine NCC ID." >&2
  exit 1
fi

RULES="$(account_api_json GET "/api/2.0/accounts/${DATABRICKS_ACCOUNT_ID}/network-connectivity-configs/${NCC_ID}/private-endpoint-rules")"
RULE_ID="$(jq -r \
  --arg resource_id "${LOGIN_PROXY_PRIVATE_LINK_SERVICE_ID}" \
  --arg domain "${LOGIN_PROXY_DOMAIN}" \
  '.items[]? | select((.resource_id == $resource_id) and ((.domain_names // []) | index($domain))) | .rule_id // .private_endpoint_rule_id // .id' \
  <<<"${RULES}" | head -n 1)"

if [[ -z "${RULE_ID}" || "${RULE_ID}" == "null" ]]; then
  echo "Creating private endpoint rule for ${LOGIN_PROXY_DOMAIN}..."
  RULE="$(account_api_json POST "/api/2.0/accounts/${DATABRICKS_ACCOUNT_ID}/network-connectivity-configs/${NCC_ID}/private-endpoint-rules" "$(jq -n \
    --arg resource_id "${LOGIN_PROXY_PRIVATE_LINK_SERVICE_ID}" \
    --arg domain "${LOGIN_PROXY_DOMAIN}" \
    '{resource_id: $resource_id, domain_names: [$domain]}')")"
  RULE_ID="$(jq -r '.rule_id // .private_endpoint_rule_id // .id' <<<"${RULE}")"
else
  echo "Reusing private endpoint rule ${RULE_ID}."
fi

if [[ -z "${RULE_ID}" || "${RULE_ID}" == "null" ]]; then
  echo "Could not determine private endpoint rule ID." >&2
  exit 1
fi

echo "Attaching NCC ${NCC_ID} to workspace ${WORKSPACE_ID}..."
account_api_json PATCH "/api/2.0/accounts/${DATABRICKS_ACCOUNT_ID}/workspaces/${WORKSPACE_ID}" "$(jq -n \
  --arg ncc_id "${NCC_ID}" \
  '{network_connectivity_config_id: $ncc_id}')" >/dev/null

echo "Waiting for workspace to return to RUNNING..."
START_TIME="$(date +%s)"
while true; do
  WORKSPACE="$(account_api_json GET "/api/2.0/accounts/${DATABRICKS_ACCOUNT_ID}/workspaces/${WORKSPACE_ID}")"
  STATUS="$(jq -r '.workspace_status // .status // empty' <<<"${WORKSPACE}")"
  echo "Workspace status: ${STATUS:-unknown}"

  if [[ "${STATUS}" == "RUNNING" ]]; then
    break
  fi

  if [[ "${STATUS}" == "FAILED" || "${STATUS}" == "CANCELLED" || "${STATUS}" == "BANNED" ]]; then
    echo "${WORKSPACE}" | jq .
    exit 1
  fi

  if (( "$(date +%s)" - START_TIME > TIMEOUT_SECONDS )); then
    echo "Timed out waiting for workspace ${WORKSPACE_ID} to return to RUNNING." >&2
    echo "${WORKSPACE}" | jq .
    exit 1
  fi

  sleep "${POLL_SECONDS}"
done

echo "Private endpoint rule ${RULE_ID} created or reused."
echo "Approve the pending private endpoint connection on the Private Link Service if needed."
echo "Then wait until the rule is ESTABLISHED before running ./scripts/deploy-databricks-serving-sp-test.sh."
