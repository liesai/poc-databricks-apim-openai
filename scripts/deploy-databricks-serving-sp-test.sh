#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${TERRAFORM_DIR:-${ROOT_DIR}/terraform}"

MODEL_NAME="${MODEL_NAME:-apim_sp_serving_probe}"
ENDPOINT_NAME="${ENDPOINT_NAME:-apim-sp-serving-probe}"
JOB_NAME="${JOB_NAME:-poc-apim-openai-service-principal-serving-test}"
NOTEBOOK_NAME="${NOTEBOOK_NAME:-register_apim_sp_serving_probe}"
SECRET_SCOPE="${SECRET_SCOPE:-apim-openai-serving-sp}"
CLIENT_SECRET_KEY="${CLIENT_SECRET_KEY:-client-secret}"
POLL_SECONDS="${POLL_SECONDS:-30}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-3600}"

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

dbx_api_json_allow_404() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local response
  local http_status
  local payload

  response="$(dbx_api "${method}" "${path}" "${body}")"
  http_status="$(tail -n 1 <<<"${response}")"
  payload="$(sed '$d' <<<"${response}")"

  if [[ "${http_status}" == "404" ]]; then
    return 1
  fi

  if [[ "${http_status}" -lt 200 || "${http_status}" -ge 300 ]]; then
    echo "Databricks API ${method} ${path} failed with HTTP ${http_status}." >&2
    echo "${payload}" >&2
    exit 1
  fi

  printf '%s\n' "${payload}"
}

dbx_api_json_allow_exists() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local response
  local http_status
  local payload

  response="$(dbx_api "${method}" "${path}" "${body}")"
  http_status="$(tail -n 1 <<<"${response}")"
  payload="$(sed '$d' <<<"${response}")"

  if [[ "${http_status}" == "400" ]] && jq -e '.error_code == "RESOURCE_ALREADY_EXISTS"' <<<"${payload}" >/dev/null 2>&1; then
    return 0
  fi

  if [[ "${http_status}" -lt 200 || "${http_status}" -ge 300 ]]; then
    echo "Databricks API ${method} ${path} failed with HTTP ${http_status}." >&2
    echo "${payload}" >&2
    exit 1
  fi

  printf '%s\n' "${payload}"
}

urlencode() {
  python3 - "$1" <<'PY'
import sys
import urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=""))
PY
}

require az
require base64
require curl
require jq
require python3
require terraform

"${SCRIPT_DIR}/deploy-openai-model.sh"

RESOURCE_GROUP_NAME="$(tf_output resource_group_name)"
TENANT_ID="$(tf_output apim_protected_api_identifier_uri | cut -d/ -f3)"
APIM_URL="$(tf_output apim_openai_sp_chat_completions_url)"
APIM_AUDIENCE="$(tf_output apim_sp_jwt_audience)"
SERVING_CLIENT_ID="$(tf_output serving_client_application_id)"
WORKSPACE_NAME="$(tf_output databricks_workspace_name)"
WORKSPACE_URL="$(tf_output databricks_workspace_url)"

if [[ -n "${SERVING_CLIENT_SECRET:-}" ]]; then
  CLIENT_SECRET="${SERVING_CLIENT_SECRET}"
  echo "Using service principal secret from SERVING_CLIENT_SECRET."
else
  echo "Creating a service principal secret for '${SERVING_CLIENT_ID}'..."
  CLIENT_SECRET="$(az ad app credential reset \
    --id "${SERVING_CLIENT_ID}" \
    --display-name "databricks-serving-sp-poc" \
    --years 1 \
    --query password \
    -o tsv)"
fi

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

echo "Ensuring Databricks secret scope '${SECRET_SCOPE}'..."
dbx_api_json_allow_exists POST /api/2.0/secrets/scopes/create "$(jq -n \
  --arg scope "${SECRET_SCOPE}" \
  '{scope: $scope, initial_manage_principal: "users"}')" >/dev/null

echo "Storing service principal secret in Databricks secret scope '${SECRET_SCOPE}'."
dbx_api_json POST /api/2.0/secrets/put "$(jq -n \
  --arg scope "${SECRET_SCOPE}" \
  --arg key "${CLIENT_SECRET_KEY}" \
  --arg value "${CLIENT_SECRET}" \
  '{scope: $scope, key: $key, string_value: $value}')" >/dev/null
unset CLIENT_SECRET

NOTEBOOK_SOURCE="$(cat <<'PY'
# Databricks notebook source
import json
import textwrap

dbutils.widgets.text("model_name", "")

model_name = dbutils.widgets.get("model_name")
if not model_name:
    raise ValueError("Missing model_name")

if model_name.count(".") == 2:
    qualified_model_name = model_name
else:
    catalog = spark.sql("SELECT current_catalog()").collect()[0][0]
    schema = spark.sql("SELECT current_schema()").collect()[0][0]
    qualified_model_name = f"{catalog}.{schema}.{model_name}"

model_file = "/tmp/apim_sp_serving_probe_model.py"
with open(model_file, "w") as f:
    f.write(textwrap.dedent(r'''
        import base64
        import json
        import os
        import urllib.error
        import urllib.parse
        import urllib.request

        import mlflow.pyfunc

        class ApimServicePrincipalServingProbe(mlflow.pyfunc.PythonModel):
            def _decode_jwt_payload(self, jwt_token):
                payload = jwt_token.split(".")[1]
                payload += "=" * (-len(payload) % 4)
                return json.loads(base64.urlsafe_b64decode(payload.encode("utf-8")).decode("utf-8"))

            def _get_token(self, tenant_id, client_id, client_secret, audience):
                token_url = f"https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/token"
                form = urllib.parse.urlencode({
                    "client_id": client_id,
                    "client_secret": client_secret,
                    "grant_type": "client_credentials",
                    "scope": audience.rstrip("/") + "/.default",
                }).encode("utf-8")
                request = urllib.request.Request(
                    token_url,
                    data=form,
                    headers={"Content-Type": "application/x-www-form-urlencoded"},
                    method="POST",
                )
                with urllib.request.urlopen(request, timeout=120) as response:
                    return json.loads(response.read().decode("utf-8"))["access_token"]

            def predict(self, context, model_input, params=None):
                tenant_id = os.environ.get("TENANT_ID")
                client_id = os.environ.get("CLIENT_ID")
                client_secret = os.environ.get("CLIENT_SECRET")
                apim_url = os.environ.get("APIM_URL")
                apim_audience = os.environ.get("APIM_AUDIENCE")

                missing = [
                    name for name, value in {
                        "TENANT_ID": tenant_id,
                        "CLIENT_ID": client_id,
                        "CLIENT_SECRET": client_secret,
                        "APIM_URL": apim_url,
                        "APIM_AUDIENCE": apim_audience,
                    }.items()
                    if not value
                ]
                if missing:
                    raise ValueError(f"Missing environment variables: {', '.join(missing)}")

                token = self._get_token(tenant_id, client_id, client_secret, apim_audience)
                claims = self._decode_jwt_payload(token)

                payload = {
                    "messages": [
                        {
                            "role": "user",
                            "content": "Reponds exactement par sp-ok si tu recois cet appel."
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
                        "roles": claims.get("roles"),
                    }
                    raise RuntimeError(
                        f"APIM call failed with HTTP {exc.code}: {body}; "
                        f"token_claims={json.dumps(safe_claims, ensure_ascii=False)}"
                    ) from exc

                data = json.loads(body)
                message = data["choices"][0]["message"]["content"]
                result = {
                    "status": status,
                    "auth_flow": "service_principal_client_credentials",
                    "apim_url": apim_url,
                    "apim_audience": apim_audience,
                    "token_aud": claims.get("aud"),
                    "token_azp": claims.get("azp"),
                    "token_appid": claims.get("appid"),
                    "token_roles": claims.get("roles"),
                    "model_response": message,
                }
                return [result]
    '''))

import importlib.util
import mlflow

spec = importlib.util.spec_from_file_location("apim_sp_serving_probe_model", model_file)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

signature = mlflow.models.infer_signature(
    [{"probe": "serving"}],
    [{
        "status": 200,
        "auth_flow": "service_principal_client_credentials",
        "apim_url": "https://example.invalid",
        "apim_audience": "api://tenant/app",
        "token_aud": "api://tenant/app",
        "token_azp": "00000000-0000-0000-0000-000000000000",
        "token_appid": None,
        "token_roles": ["APIM.Proxy.Invoke"],
        "model_response": "sp-ok",
    }]
)

with mlflow.start_run():
    model_info = mlflow.pyfunc.log_model(
        artifact_path="model",
        python_model=module.ApimServicePrincipalServingProbe(),
        registered_model_name=qualified_model_name,
        signature=signature,
        input_example=[{"probe": "serving"}],
        code_paths=[model_file],
    )

client = mlflow.tracking.MlflowClient()
model_version = getattr(model_info, "registered_model_version", None)
if model_version is None:
    versions = client.search_model_versions(f"name = '{qualified_model_name}'")
    if not versions:
        raise RuntimeError(f"No registered model versions found for {qualified_model_name}")
    model_version = max(versions, key=lambda version: int(version.version)).version

result = {
    "model_name": qualified_model_name,
    "model_version": str(model_version),
    "model_uri": f"models:/{qualified_model_name}/{model_version}",
}
print(json.dumps(result, ensure_ascii=False, indent=2))
dbutils.notebook.exit(json.dumps(result, ensure_ascii=False))
PY
)"

echo "Importing registration notebook '${NOTEBOOK_PATH}'..."
dbx_api_json POST /api/2.0/workspace/import "$(jq -n \
  --arg path "${NOTEBOOK_PATH}" \
  --arg content "$(printf '%s' "${NOTEBOOK_SOURCE}" | base64 -w 0)" \
  '{path: $path, format: "SOURCE", language: "PYTHON", content: $content, overwrite: true}')" >/dev/null

JOB_ID="$(dbx_api_json GET "/api/2.1/jobs/list?name=$(urlencode "${JOB_NAME}")" | jq -r --arg name "${JOB_NAME}" '.jobs[]? | select(.settings.name == $name) | .job_id' | head -n 1)"

JOB_SETTINGS="$(jq -n \
  --arg name "${JOB_NAME}" \
  --arg notebook_path "${NOTEBOOK_PATH}" \
  --arg model_name "${MODEL_NAME}" \
  '{
    name: $name,
    max_concurrent_runs: 1,
    tasks: [
      {
        task_key: "register_serving_sp_probe_model",
        notebook_task: {
          notebook_path: $notebook_path,
          base_parameters: {
            model_name: $model_name
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

echo "Starting model registration job run..."
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

TASK_RUN_ID="$(jq -r '.tasks[]? | select(.task_key == "register_serving_sp_probe_model") | .run_id' <<<"${RUN}" | tail -n 1)"
OUTPUT_RUN_ID="${TASK_RUN_ID:-${RUN_ID}}"
OUTPUT="$(dbx_api_json GET "/api/2.1/jobs/runs/get-output?run_id=${OUTPUT_RUN_ID}")"
NOTEBOOK_RESULT="$(jq -r '.notebook_output.result // empty' <<<"${OUTPUT}")"

if [[ "${RESULT_STATE}" != "SUCCESS" ]]; then
  echo "${OUTPUT}" | jq -r '.notebook_output.result // .error // .metadata.state.state_message // .'
  exit 1
fi

QUALIFIED_MODEL_NAME="$(jq -r '.model_name' <<<"${NOTEBOOK_RESULT}")"
MODEL_VERSION="$(jq -r '.model_version' <<<"${NOTEBOOK_RESULT}")"
SERVED_ENTITY_NAME="apim_sp_probe_v${MODEL_VERSION}"

echo "Registered model ${QUALIFIED_MODEL_NAME} version ${MODEL_VERSION}."
echo "Creating or updating serving endpoint '${ENDPOINT_NAME}'..."

ENDPOINT_CONFIG="$(jq -n \
  --arg endpoint_name "${ENDPOINT_NAME}" \
  --arg served_entity_name "${SERVED_ENTITY_NAME}" \
  --arg model_name "${QUALIFIED_MODEL_NAME}" \
  --arg model_version "${MODEL_VERSION}" \
  --arg tenant_id "${TENANT_ID}" \
  --arg client_id "${SERVING_CLIENT_ID}" \
  --arg client_secret_ref "{{secrets/${SECRET_SCOPE}/${CLIENT_SECRET_KEY}}}" \
  --arg apim_url "${APIM_URL}" \
  --arg apim_audience "${APIM_AUDIENCE}" \
  '{
    name: $endpoint_name,
    config: {
      served_entities: [
        {
          name: $served_entity_name,
          entity_name: $model_name,
          entity_version: $model_version,
          workload_size: "Small",
          scale_to_zero_enabled: true,
          environment_vars: {
            TENANT_ID: $tenant_id,
            CLIENT_ID: $client_id,
            CLIENT_SECRET: $client_secret_ref,
            APIM_URL: $apim_url,
            APIM_AUDIENCE: $apim_audience
          }
        }
      ],
      traffic_config: {
        routes: [
          {
            served_model_name: $served_entity_name,
            traffic_percentage: 100
          }
        ]
      }
    }
  }')"

if dbx_api_json_allow_404 GET "/api/2.0/serving-endpoints/${ENDPOINT_NAME}" >/dev/null; then
  dbx_api_json PUT "/api/2.0/serving-endpoints/${ENDPOINT_NAME}/config" "$(jq '.config' <<<"${ENDPOINT_CONFIG}")" >/dev/null
else
  dbx_api_json POST /api/2.0/serving-endpoints "${ENDPOINT_CONFIG}" >/dev/null
fi

echo "Waiting for serving endpoint '${ENDPOINT_NAME}' to become READY..."
START_TIME="$(date +%s)"
while true; do
  ENDPOINT="$(dbx_api_json GET "/api/2.0/serving-endpoints/${ENDPOINT_NAME}")"
  READY_STATE="$(jq -r '.state.ready // empty' <<<"${ENDPOINT}")"
  UPDATE_STATE="$(jq -r '.state.config_update // empty' <<<"${ENDPOINT}")"
  CONFIG_VERSION="$(jq -r '.config.config_version // .pending_config.config_version // empty' <<<"${ENDPOINT}")"
  echo "Endpoint state: ready=${READY_STATE:-unknown} update=${UPDATE_STATE:-unknown} config_version=${CONFIG_VERSION:-unknown}"

  if [[ "${READY_STATE}" == "READY" && "${UPDATE_STATE}" != "UPDATE_FAILED" ]]; then
    break
  fi

  if [[ "${READY_STATE}" == "NOT_READY" && "${UPDATE_STATE}" == "UPDATE_FAILED" ]]; then
    echo "${ENDPOINT}" | jq .
    exit 1
  fi

  if (( "$(date +%s)" - START_TIME > TIMEOUT_SECONDS )); then
    echo "Timed out waiting for serving endpoint ${ENDPOINT_NAME}." >&2
    echo "${ENDPOINT}" | jq .
    exit 1
  fi

  sleep "${POLL_SECONDS}"
done

echo "Invoking serving endpoint '${ENDPOINT_NAME}'..."
INVOCATION_RESULT="$(dbx_api_json POST "/serving-endpoints/${ENDPOINT_NAME}/invocations" '{"dataframe_records":[{"probe":"serving"}]}')"
echo "${INVOCATION_RESULT}" | jq .

echo "Databricks Model Serving service principal test completed."
