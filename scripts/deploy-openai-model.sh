#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${TERRAFORM_DIR:-${ROOT_DIR}/terraform}"

MODEL_DEPLOYMENT_NAME="${MODEL_DEPLOYMENT_NAME:-gpt-4o-mini}"
MODEL_NAME="${MODEL_NAME:-gpt-4.1-mini}"
MODEL_FORMAT="${MODEL_FORMAT:-OpenAI}"
MODEL_SKU_NAME="${MODEL_SKU_NAME:-Standard}"
MODEL_SKU_CAPACITY="${MODEL_SKU_CAPACITY:-1}"

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

tf_output() {
  terraform -chdir="${TERRAFORM_DIR}" output -raw "$1"
}

require az
require jq
require terraform

RESOURCE_GROUP_NAME="$(tf_output resource_group_name)"
OPENAI_ACCOUNT_NAME="$(tf_output azure_openai_account_name)"

if az cognitiveservices account deployment show \
  --resource-group "${RESOURCE_GROUP_NAME}" \
  --name "${OPENAI_ACCOUNT_NAME}" \
  --deployment-name "${MODEL_DEPLOYMENT_NAME}" \
  >/dev/null 2>&1; then
  echo "Deployment '${MODEL_DEPLOYMENT_NAME}' already exists on '${OPENAI_ACCOUNT_NAME}'."
  az cognitiveservices account deployment show \
    --resource-group "${RESOURCE_GROUP_NAME}" \
    --name "${OPENAI_ACCOUNT_NAME}" \
    --deployment-name "${MODEL_DEPLOYMENT_NAME}" \
    --query "{name:name, model:properties.model.name, version:properties.model.version, sku:sku.name, capacity:sku.capacity}" \
    -o table
  exit 0
fi

MODEL_VERSION="${MODEL_VERSION:-$(az cognitiveservices account list-models \
  --resource-group "${RESOURCE_GROUP_NAME}" \
  --name "${OPENAI_ACCOUNT_NAME}" \
  --query "[?name=='${MODEL_NAME}' && format=='${MODEL_FORMAT}' && isDefaultVersion].version | [0]" \
  -o tsv)}"

if [[ -z "${MODEL_VERSION}" ]]; then
  echo "Unable to resolve default version for model '${MODEL_NAME}' in account '${OPENAI_ACCOUNT_NAME}'." >&2
  echo "Set MODEL_VERSION explicitly and retry." >&2
  exit 1
fi

echo "Creating Azure OpenAI deployment '${MODEL_DEPLOYMENT_NAME}' (${MODEL_NAME}:${MODEL_VERSION})..."
az cognitiveservices account deployment create \
  --resource-group "${RESOURCE_GROUP_NAME}" \
  --name "${OPENAI_ACCOUNT_NAME}" \
  --deployment-name "${MODEL_DEPLOYMENT_NAME}" \
  --model-format "${MODEL_FORMAT}" \
  --model-name "${MODEL_NAME}" \
  --model-version "${MODEL_VERSION}" \
  --sku-name "${MODEL_SKU_NAME}" \
  --sku-capacity "${MODEL_SKU_CAPACITY}" \
  -o table

echo "Deployment ready."
