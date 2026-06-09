# Sequence de deploiement de la POC Databricks Serving, APIM et proxy login

Ce document decrit la sequence utilisee pour deployer la POC complete :

```text
Databricks Model Serving
  -> login.microsoftonline.com via NCC
  -> Databricks-managed private endpoint
  -> Azure Private Link Service
  -> Internal Load Balancer
  -> VM HAProxy
  -> NAT Gateway
  -> login.microsoftonline.com
  -> APIM
  -> Azure OpenAI
```

L'objectif de cette POC est de prouver que le flux OAuth2 `client_credentials` emis par un Databricks Model Serving endpoint vers `login.microsoftonline.com` peut etre route via NCC, Private Link Service, Internal Load Balancer et HAProxy, tout en conservant une authentification Entra ID normale.

## Prerequis

Se placer a la racine du repo :

```bash
cd /home/marc/poc-databricks-apim-openai
```

S'authentifier a Azure :

```bash
az login
az account set --subscription 636cafa7-3704-452b-bc87-3a11c9bde98a
```

Verifier la configuration Terraform dans `terraform/terraform.tfvars` :

```hcl
subscription_id = "636cafa7-3704-452b-bc87-3a11c9bde98a"
tenant_id       = "495929eb-f078-464d-b6ef-e9fe18c31e12"
location        = "francecentral"
openai_location = "swedencentral"

create_model_deployment = false
enable_databricks_public_network_access = true
apim_sku_name = "Consumption_0"
```

Installer ou verifier les outils suivants :

- Azure CLI authentifiee
- Terraform
- Databricks CLI
- `jq`
- `curl`

## 1. Deployer l'infrastructure Azure

Initialiser Terraform :

```bash
terraform -chdir=terraform init
```

Deployer l'infrastructure :

```bash
terraform -chdir=terraform apply -auto-approve
```

Cette etape cree notamment :

- le resource group de la POC
- le workspace Azure Databricks
- le compte Azure OpenAI
- APIM
- les applications Entra ID et service principals
- le VNet et les subnets du proxy login
- le NAT Gateway
- la VM HAProxy
- l'Internal Load Balancer
- le Private Link Service
- le Databricks Access Connector

Les outputs Terraform importants sont consultables avec :

```bash
terraform -chdir=terraform output
```

Pour la derniere execution de la POC, les valeurs observees etaient :

```text
Resource group: rg-dbxapimpoc-hetu61
Workspace: dbxapimpoc-hetu61-dbx
Workspace URL: adb-7405608417350626.6.azuredatabricks.net
APIM URL: https://dbxapimpochetu61apim.azure-api.net
APIM SP route: https://dbxapimpochetu61apim.azure-api.net/openai/sp/chat/completions
Azure OpenAI account: dbxapimpochetu61aoai
Azure OpenAI endpoint: https://dbxapimpocaoaihetu61.openai.azure.com/
Login proxy VM: dbxapimpochetu61lpvm
Login proxy NAT IP: 20.199.102.27
Serving client application ID: f79f81d7-7c0a-4da7-b82d-846ebd159669
```

## 2. Deployer le modele Azure OpenAI

Le script suivant cree le deployment Azure OpenAI attendu par APIM :

```bash
./scripts/deploy-openai-model.sh
```

Dans la POC, le deployment cree est :

```text
gpt-4o-mini
```

Le script s'appuie sur les outputs Terraform pour retrouver le resource group et le compte Azure OpenAI.

## 3. Configurer le routage prive Databricks vers login.microsoftonline.com

Executer :

```bash
./scripts/configure-databricks-login-proxy-ncc.sh
```

Ce script configure la partie Databricks Account / NCC :

- creation ou reutilisation d'une Network Connectivity Configuration
- creation d'une private endpoint rule Databricks pour `login.microsoftonline.com`
- association du NCC au workspace Databricks
- attente de la creation du private endpoint Databricks-managed
- approbation de la connexion Private Link cote Azure Private Link Service
- attente de l'etat `ESTABLISHED`

Le chemin vise est :

```text
Databricks Model Serving
  -> NCC domain rule pour login.microsoftonline.com
  -> Databricks-managed private endpoint
  -> Azure Private Link Service
  -> Azure Internal Load Balancer
  -> VM HAProxy
  -> NAT Gateway
  -> login.microsoftonline.com
```

Pour la derniere execution, les valeurs observees etaient :

```text
Databricks account ID: c40e0133-b08f-4d33-b892-ea9052199bf3
NCC ID: 05803ba0-a04f-45d2-bd4e-9aa49e344e5c
Private endpoint rule ID: fe5ed188-1bb6-4a4e-9e38-ef71d630fef8
Domain: login.microsoftonline.com
Endpoint name: databricks-05803ba0-a04f-45d2-bd4e-9aa49e344e5c-pe-2d668883
Rule status: ESTABLISHED
```

## 4. Deployer le modele pyfunc et le Serving Endpoint

Executer :

```bash
./scripts/deploy-databricks-serving-sp-test.sh
```

Ce script realise toute la partie Databricks Serving :

- creation ou rotation du secret du service principal Entra utilise par le serving endpoint
- creation du secret scope Databricks `apim-openai-serving-sp`
- stockage du client secret dans le secret Databricks `client-secret`
- creation d'un notebook de registration MLflow
- execution d'un job Databricks qui enregistre le modele pyfunc
- enregistrement du modele dans Unity Catalog
- creation ou mise a jour du Serving Endpoint
- attente de l'etat `READY`
- invocation de test du Serving Endpoint

Dans la derniere execution, le modele Unity Catalog etait :

```text
dbxapimpoc_hetu61_dbx.default.apim_sp_serving_probe
```

Le Serving Endpoint etait :

```text
apim-sp-serving-probe
```

La configuration du Serving Endpoint injecte les variables suivantes dans le runtime pyfunc :

```text
TENANT_ID
CLIENT_ID
CLIENT_SECRET
APIM_URL
APIM_AUDIENCE
```

Exemple de configuration observee :

```json
{
  "TENANT_ID": "495929eb-f078-464d-b6ef-e9fe18c31e12",
  "CLIENT_ID": "f79f81d7-7c0a-4da7-b82d-846ebd159669",
  "CLIENT_SECRET": "{{secrets/apim-openai-serving-sp/client-secret}}",
  "APIM_URL": "https://dbxapimpochetu61apim.azure-api.net/openai/sp/chat/completions",
  "APIM_AUDIENCE": "api://495929eb-f078-464d-b6ef-e9fe18c31e12/dbxapimpoc-hetu61-apim-api"
}
```

## 5. Invocation de validation

Le script `deploy-databricks-serving-sp-test.sh` invoque le endpoint automatiquement.

Pour rejouer manuellement l'appel :

```bash
RESOURCE_GROUP_NAME="$(terraform -chdir=terraform output -raw resource_group_name)"
WORKSPACE_NAME="$(terraform -chdir=terraform output -raw databricks_workspace_name)"
WORKSPACE_URL="$(terraform -chdir=terraform output -raw databricks_workspace_url)"
WORKSPACE_RESOURCE_ID="$(az databricks workspace show \
  -g "${RESOURCE_GROUP_NAME}" \
  -n "${WORKSPACE_NAME}" \
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

curl -sS \
  -H "Authorization: Bearer ${DATABRICKS_TOKEN}" \
  -H "X-Databricks-Azure-SP-Management-Token: ${AZURE_MANAGEMENT_TOKEN}" \
  -H "X-Databricks-Azure-Workspace-Resource-Id: ${WORKSPACE_RESOURCE_ID}" \
  -H "Content-Type: application/json" \
  -X POST \
  --data '{"dataframe_records":[{"probe":"serving"}]}' \
  "https://${WORKSPACE_URL}/serving-endpoints/apim-sp-serving-probe/invocations"
```

Resultat attendu :

```json
{
  "status": 200,
  "auth_flow": "service_principal_client_credentials",
  "apim_url": "https://dbxapimpochetu61apim.azure-api.net/openai/sp/chat/completions",
  "apim_audience": "api://495929eb-f078-464d-b6ef-e9fe18c31e12/dbxapimpoc-hetu61-apim-api",
  "token_aud": "691c5444-bb39-436e-ad4d-6141641f4497",
  "token_azp": "f79f81d7-7c0a-4da7-b82d-846ebd159669",
  "token_roles": ["APIM.Proxy.Invoke"],
  "model_response": "sp-ok"
}
```

## 6. Verification du passage par HAProxy

Le test fonctionnel APIM ne suffit pas a prouver que le flux `login.microsoftonline.com` passe par HAProxy. Pour le prouver, capturer le trafic sur la VM pendant une invocation du Serving Endpoint.

Installer `tcpdump` si necessaire :

```bash
az vm run-command invoke \
  -g rg-dbxapimpoc-hetu61 \
  -n dbxapimpochetu61lpvm \
  --command-id RunShellScript \
  --scripts "sudo apt-get update -y >/dev/null && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y tcpdump >/dev/null || true; tcpdump --version | head -1"
```

Lancer une capture pendant l'invocation :

```bash
az vm run-command invoke \
  -g rg-dbxapimpoc-hetu61 \
  -n dbxapimpochetu61lpvm \
  --command-id RunShellScript \
  --scripts "sudo timeout 75 tcpdump -nn -tttt -i any 'tcp port 443' -c 80"
```

En parallele, invoquer le Serving Endpoint comme decrit dans la section precedente.

La preuve attendue est une sequence de ce type :

```text
10.80.2.x -> 10.80.1.5:443
10.80.1.5 -> <IP Microsoft Entra>:443
```

Cela montre :

- une connexion entrante depuis le chemin Private Link Databricks vers la VM HAProxy
- une connexion sortante de HAProxy vers `login.microsoftonline.com`
- donc le flux token du Serving Endpoint passe bien par le proxy

## Scripts utilises

Scripts principaux :

```text
scripts/deploy-openai-model.sh
scripts/configure-databricks-login-proxy-ncc.sh
scripts/deploy-databricks-serving-sp-test.sh
```

Scripts de comparaison ou de preuve negative :

```text
scripts/deploy-databricks-serving-mi-test.sh
scripts/deploy-databricks-mi-pipeline.sh
```

`scripts/deploy-databricks-serving-mi-test.sh` sert a prouver la limite Managed Identity dans Databricks Model Serving. Le runtime pyfunc Serving ne fournit pas les providers necessaires comme `databricks.service_credentials` ou `dbutils.credentials`, donc le modele ne peut pas obtenir directement une Unity Catalog service credential ou une managed identity.

`scripts/deploy-databricks-mi-pipeline.sh` sert a comparer avec un contexte notebook/job Databricks, ou les service credentials peuvent etre disponibles.

## Point cle sur l'authentification

Cette POC ne contourne pas l'authentification Entra ID.

Le proxy HAProxy transporte le flux TLS vers `login.microsoftonline.com` en passthrough TCP. L'identite reste celle du service principal :

```text
CLIENT_ID + CLIENT_SECRET + TENANT_ID
```

Le proxy controle uniquement le chemin reseau et l'IP de sortie vers Entra ID. Il ne fabrique pas de token, ne modifie pas le token et ne remplace pas Entra ID.

## Limite Managed Identity constatee

Le test Managed Identity echoue dans Model Serving avant l'appel APIM, au moment ou le modele tente d'obtenir un provider de credentials Databricks.

Les mecanismes testes sont :

```python
from databricks.service_credentials import getServiceCredentialsProvider
dbutils.credentials.getServiceCredentialsProvider(...)
```

Dans le runtime Model Serving pyfunc, ces providers ne sont pas exposes comme dans un notebook ou un job. Installer une librairie Python au demarrage du modele ne suffit pas a creer une managed identity ni a monter le provider Databricks manquant.

La conclusion de la POC est donc :

- le routage prive du flux `login.microsoftonline.com` depuis Model Serving est possible
- l'appel APIM avec JWT Entra ID depuis Model Serving est possible via service principal
- l'utilisation directe d'une managed identity depuis le runtime pyfunc Model Serving n'a pas ete possible avec les providers disponibles
