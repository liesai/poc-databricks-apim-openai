#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${TERRAFORM_DIR:-${ROOT_DIR}/terraform}"

SERVICE_CREDENTIAL_NAME="${SERVICE_CREDENTIAL_NAME:-apim_openai_mi}"
JOB_NAME="${JOB_NAME:-poc-apim-openai-managed-identity-test}"
NOTEBOOK_NAME="${NOTEBOOK_NAME:-test_apim_managed_identity}"
MODEL_DEPLOYMENT_NAME="${MODEL_DEPLOYMENT_NAME:-gpt-4o-mini}"
OPENAI_API_VERSION="${OPENAI_API_VERSION:-2024-10-21}"
POLL_SECONDS="${POLL_SECONDS:-20}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-1800}"

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

tf_output() {
  terraform -chdir="${TERRAFORM_DIR}" output -raw "$1"
}

dbx_api() {
  local method="$1"
  local path="$2"
  local body="${3:-}"

  local args=(
    -sS
    -X "${method}"
    -H "Authorization: Bearer ${DATABRICKS_TOKEN}"
    -H "X-Databricks-Azure-SP-Management-Token: ${AZURE_MANAGEMENT_TOKEN}"
    -H "X-Databricks-Azure-Workspace-Resource-Id: ${DATABRICKS_WORKSPACE_RESOURCE_ID}"
    -H "Content-Type: application/json"
    -w $'\n%{http_code}'
  )

  if [[ -n "${body}" ]]; then
    args+=(--data "${body}")
  fi

  curl "${args[@]}" "${DATABRICKS_HOST}${path}"
}

dbx_api_json() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local response
  local http_status
  local payload

  response="$(dbx_api "${method}" "${path}" "${body}")"
  http_status="$(tail -n 1 <<<"${response}")"
  payload="$(sed '$d' <<<"${response}")"

  if [[ "${http_status}" -lt 200 || "${http_status}" -ge 300 ]]; then
    echo "Databricks API ${method} ${path} failed with HTTP ${http_status}." >&2
    echo "${payload}" >&2
    exit 1
  fi

  printf '%s\n' "${payload}"
}

require az
require base64
require curl
require jq
require terraform

"${SCRIPT_DIR}/deploy-openai-model.sh"

RESOURCE_GROUP_NAME="$(tf_output resource_group_name)"
APIM_URL="$(tf_output apim_openai_chat_completions_url)"
APIM_AUDIENCE="$(tf_output apim_jwt_audience)"
ACCESS_CONNECTOR_ID="$(tf_output databricks_access_connector_id)"
WORKSPACE_NAME="$(tf_output databricks_workspace_name)"
WORKSPACE_URL="$(tf_output databricks_workspace_url)"

DATABRICKS_HOST="https://${WORKSPACE_URL}"
DATABRICKS_WORKSPACE_RESOURCE_ID="$(az databricks workspace show \
  --resource-group "${RESOURCE_GROUP_NAME}" \
  --name "${WORKSPACE_NAME}" \
  --query id \
  -o tsv)"
DATABRICKS_TOKEN="$(az account get-access-token \
  --resource 2ff814a6-3304-4ab8-85cb-cd0e6f879c1d \
  --query accessToken \
  -o tsv)"
AZURE_MANAGEMENT_TOKEN="$(az account get-access-token \
  --resource https://management.core.windows.net/ \
  --query accessToken \
  -o tsv)"

CURRENT_USER="$(dbx_api_json GET /api/2.0/preview/scim/v2/Me | jq -r '.userName')"
NOTEBOOK_PATH="/Users/${CURRENT_USER}/${NOTEBOOK_NAME}"

echo "Ensuring Unity Catalog service credential '${SERVICE_CREDENTIAL_NAME}'..."
if ! dbx_api_json GET "/api/2.1/unity-catalog/credentials/${SERVICE_CREDENTIAL_NAME}" >/dev/null 2>&1; then
  dbx_api_json POST /api/2.1/unity-catalog/credentials "$(jq -n \
    --arg name "${SERVICE_CREDENTIAL_NAME}" \
    --arg access_connector_id "${ACCESS_CONNECTOR_ID}" \
    '{
      name: $name,
      purpose: "SERVICE",
      azure_managed_identity: {access_connector_id: $access_connector_id},
      comment: "POC APIM/OpenAI authentication test from Databricks",
      skip_validation: true
    }')" >/dev/null
fi

NOTEBOOK_SOURCE="$(cat <<'PY'
# Databricks notebook source
import base64
import json
import urllib.error
import urllib.request

dbutils.widgets.text("service_credential_name", "")
dbutils.widgets.text("apim_url", "")
dbutils.widgets.text("apim_audience", "")

service_credential_name = dbutils.widgets.get("service_credential_name")
apim_url = dbutils.widgets.get("apim_url")
apim_audience = dbutils.widgets.get("apim_audience")

if not service_credential_name:
    raise ValueError("Missing service_credential_name")
if not apim_url:
    raise ValueError("Missing apim_url")
if not apim_audience:
    raise ValueError("Missing apim_audience")

credential = dbutils.credentials.getServiceCredentialsProvider(service_credential_name)
token_scope = apim_audience.rstrip("/") + "/.default"
token = credential.get_token(token_scope).token

def decode_jwt_payload(jwt_token):
    payload = jwt_token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    return json.loads(base64.urlsafe_b64decode(payload.encode("utf-8")).decode("utf-8"))

claims = decode_jwt_payload(token)

payload = {
    "messages": [
        {
            "role": "user",
            "content": "Réponds exactement par mi-ok si tu reçois cet appel."
        }
    ],
    "max_tokens": 16,
    "temperature": 0
}

request = urllib.request.Request(
    apim_url,
    data=json.dumps(payload).encode("utf-8"),
    headers={
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json"
    },
    method="POST"
)

try:
    with urllib.request.urlopen(request, timeout=120) as response:
        body = response.read().decode("utf-8")
        status = response.status
except urllib.error.HTTPError as exc:
    body = exc.read().decode("utf-8")
    safe_claims = {
        "aud": claims.get("aud"),
        "iss": claims.get("iss"),
        "oid": claims.get("oid"),
        "appid": claims.get("appid"),
        "azp": claims.get("azp"),
        "tid": claims.get("tid"),
        "xms_mirid": claims.get("xms_mirid"),
        "roles": claims.get("roles"),
        "scp": claims.get("scp")
    }
    raise RuntimeError(f"APIM call failed with HTTP {exc.code}: {body}; token_claims={json.dumps(safe_claims, ensure_ascii=False)}") from exc

data = json.loads(body)
message = data["choices"][0]["message"]["content"]
result = {
    "status": status,
    "service_credential": service_credential_name,
    "apim_url": apim_url,
    "apim_audience": apim_audience,
    "token_aud": claims.get("aud"),
    "token_oid": claims.get("oid"),
    "token_appid": claims.get("appid"),
    "model_response": message
}
print(json.dumps(result, ensure_ascii=False, indent=2))
dbutils.notebook.exit(json.dumps(result, ensure_ascii=False))
PY
)"

echo "Importing notebook '${NOTEBOOK_PATH}'..."
dbx_api_json POST /api/2.0/workspace/import "$(jq -n \
  --arg path "${NOTEBOOK_PATH}" \
  --arg content "$(printf '%s' "${NOTEBOOK_SOURCE}" | base64 -w 0)" \
  '{path: $path, format: "SOURCE", language: "PYTHON", content: $content, overwrite: true}')" >/dev/null

JOB_ID="$(dbx_api_json GET "/api/2.1/jobs/list?name=$(python3 - <<PY
import urllib.parse
print(urllib.parse.quote("${JOB_NAME}"))
PY
)" | jq -r --arg name "${JOB_NAME}" '.jobs[]? | select(.settings.name == $name) | .job_id' | head -n 1)"

JOB_SETTINGS="$(jq -n \
  --arg name "${JOB_NAME}" \
  --arg notebook_path "${NOTEBOOK_PATH}" \
  --arg service_credential_name "${SERVICE_CREDENTIAL_NAME}" \
  --arg apim_url "${APIM_URL}" \
  --arg apim_audience "${APIM_AUDIENCE}" \
  '{
    name: $name,
    max_concurrent_runs: 1,
    tasks: [
      {
        task_key: "test_apim_managed_identity",
        notebook_task: {
          notebook_path: $notebook_path,
          base_parameters: {
            service_credential_name: $service_credential_name,
            apim_url: $apim_url,
            apim_audience: $apim_audience
          }
        }
      }
    ]
  }')"

if [[ -n "${JOB_ID}" ]]; then
  echo "Updating Databricks job '${JOB_NAME}' (${JOB_ID})..."
  dbx_api_json POST /api/2.1/jobs/reset "$(jq -n \
    --argjson job_id "${JOB_ID}" \
    --argjson new_settings "${JOB_SETTINGS}" \
    '{job_id: $job_id, new_settings: $new_settings}')" >/dev/null
else
  echo "Creating Databricks job '${JOB_NAME}'..."
  JOB_ID="$(dbx_api_json POST /api/2.1/jobs/create "${JOB_SETTINGS}" | jq -r '.job_id')"
fi

echo "Starting Databricks job run..."
RUN_ID="$(dbx_api_json POST /api/2.1/jobs/run-now "$(jq -n --argjson job_id "${JOB_ID}" '{job_id: $job_id}')" | jq -r '.run_id')"
echo "Run ID: ${RUN_ID}"

START_TIME="$(date +%s)"
while true; do
  RUN="$(dbx_api_json GET "/api/2.1/jobs/runs/get?run_id=${RUN_ID}")"
  LIFE_CYCLE_STATE="$(jq -r '.state.life_cycle_state' <<<"${RUN}")"
  RESULT_STATE="$(jq -r '.state.result_state // empty' <<<"${RUN}")"
  STATE_MESSAGE="$(jq -r '.state.state_message // empty' <<<"${RUN}")"

  echo "Run state: ${LIFE_CYCLE_STATE}${RESULT_STATE:+ / ${RESULT_STATE}}${STATE_MESSAGE:+ - ${STATE_MESSAGE}}"

  if [[ "${LIFE_CYCLE_STATE}" == "TERMINATED" || "${LIFE_CYCLE_STATE}" == "SKIPPED" || "${LIFE_CYCLE_STATE}" == "INTERNAL_ERROR" ]]; then
    break
  fi

  if (( "$(date +%s)" - START_TIME > TIMEOUT_SECONDS )); then
    echo "Timed out waiting for run ${RUN_ID}." >&2
    exit 1
  fi

  sleep "${POLL_SECONDS}"
done

TASK_RUN_ID="$(jq -r '.tasks[]? | select(.task_key == "test_apim_managed_identity") | .run_id' <<<"${RUN}" | tail -n 1)"
OUTPUT_RUN_ID="${TASK_RUN_ID:-${RUN_ID}}"
OUTPUT="$(dbx_api_json GET "/api/2.1/jobs/runs/get-output?run_id=${OUTPUT_RUN_ID}")"
echo "${OUTPUT}" | jq -r '.notebook_output.result // .error // .metadata.state.state_message // .'

if [[ "${RESULT_STATE}" != "SUCCESS" ]]; then
  exit 1
fi

echo "Databricks managed identity pipeline succeeded."
