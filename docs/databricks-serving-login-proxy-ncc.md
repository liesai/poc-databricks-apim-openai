# Databricks Model Serving vers `login.microsoftonline.com` via NCC, Private Link Service et HAProxy

Ce document décrit le test réalisé pour vérifier si un Azure Databricks Model Serving endpoint peut obtenir son token Entra ID en redirigeant `login.microsoftonline.com` vers un chemin réseau privé contrôlé :

```text
Databricks Model Serving
  -> Databricks NCC domain rule pour login.microsoftonline.com
  -> Databricks-managed private endpoint
  -> Azure Private Link Service
  -> Azure Internal Load Balancer
  -> VM HAProxy TCP passthrough
  -> NAT Gateway / IP egress contrôlée
  -> login.microsoftonline.com
```

Le résultat du test est positif : l'invocation du serving endpoint réussit et la capture réseau sur la VM HAProxy montre une connexion entrante depuis le chemin Private Link, puis une connexion sortante de HAProxy vers une IP Microsoft Entra.

## Objectif

Le besoin testé n'est pas simplement de prouver que HAProxy peut joindre `login.microsoftonline.com` depuis une VM. Ce point est trivial et ne prouve rien pour Databricks Model Serving.

Le point à prouver est le suivant :

- un Model Serving endpoint Databricks exécute un flow OAuth2 `client_credentials` vers `https://login.microsoftonline.com/.../oauth2/v2.0/token`
- la résolution de `login.microsoftonline.com` côté serverless Databricks est redirigée par une règle NCC
- le trafic token passe effectivement par le private endpoint Databricks, le Private Link Service Azure, l'Internal Load Balancer et HAProxy
- HAProxy ressort ensuite vers Entra ID avec une IP de sortie maîtrisée
- l'appel APIM qui suit reste authentifié par JWT Entra et ne repose pas sur une API key Azure OpenAI

## Architecture validée

```text
+-----------------------------+
| Databricks Model Serving    |
| apim-sp-serving-probe       |
+--------------+--------------+
               |
               | HTTPS token request
               | login.microsoftonline.com
               v
+--------------+--------------+
| Databricks Network          |
| Connectivity Configuration  |
| domain_names:               |
| - login.microsoftonline.com |
+--------------+--------------+
               |
               | Databricks-managed PE
               v
+--------------+--------------+
| Azure Private Link Service  |
| dbxapimpoc-...-pls          |
+--------------+--------------+
               |
               | Internal LB frontend :443
               v
+--------------+--------------+
| Internal Load Balancer      |
| backend pool: VM NIC        |
+--------------+--------------+
               |
               | TCP/443
               v
+--------------+--------------+
| VM Ubuntu + HAProxy         |
| TCP passthrough             |
| bind *:443                  |
+--------------+--------------+
               |
               | NAT Gateway
               v
+--------------+--------------+
| login.microsoftonline.com   |
+-----------------------------+
```

## Ressources Azure déployées

Les ressources suivantes ont été ajoutées à l'infra Terraform pour exposer HAProxy via Private Link Service :

- `azurerm_virtual_network.login_proxy`
  - VNet dédié au proxy : `10.80.0.0/16`
- `azurerm_subnet.login_proxy_vm`
  - subnet VM : `10.80.1.0/24`
  - associé au NAT Gateway
  - associé au NSG
- `azurerm_subnet.login_proxy_pls`
  - subnet PLS : `10.80.2.0/24`
  - `private_link_service_network_policies_enabled = false`
- `azurerm_network_security_group.login_proxy`
  - autorise TCP/443 depuis `VirtualNetwork`
- `azurerm_public_ip.login_proxy_nat`
  - IP publique de sortie du NAT Gateway
  - valeur observée pendant la POC : `20.216.128.52`
- `azurerm_nat_gateway.login_proxy`
  - contrôle l'egress de la VM HAProxy
- `azurerm_network_interface.login_proxy`
  - NIC privée de la VM HAProxy
  - IP observée : `10.80.1.5`
- `azurerm_linux_virtual_machine.login_proxy`
  - VM Ubuntu 22.04
  - taille : `Standard_B1s`
  - pas de container : HAProxy est installé directement sur la VM afin d'avoir un vrai NIC backend derrière l'Internal Load Balancer
- `azurerm_lb.login_proxy`
  - Load Balancer interne Standard
  - frontend privé dans le subnet VM
- `azurerm_lb_backend_address_pool.login_proxy`
  - backend pool contenant la NIC de la VM
- `azurerm_lb_probe.login_proxy`
  - probe TCP/443
- `azurerm_lb_rule.login_proxy`
  - frontend TCP/443 vers backend TCP/443
- `azurerm_private_link_service.login_proxy`
  - exposé devant l'Internal Load Balancer
  - `visibility_subscription_ids = [var.subscription_id]`
  - `auto_approval_subscription_ids = [var.subscription_id]`

L'auto-approval ne suffit pas pour le private endpoint créé par Databricks, car celui-ci est créé dans une souscription Microsoft/Databricks managed différente. La connexion PLS a donc été approuvée explicitement côté Azure.

## Configuration HAProxy

HAProxy est configuré en TCP passthrough. Il ne termine pas TLS, ne modifie pas le certificat, ne fait pas de MITM et ne contourne pas l'authentification.

Configuration appliquée :

```haproxy
global
    log /dev/log local0
    maxconn 2048

defaults
    log global
    mode tcp
    option tcplog
    timeout connect 10s
    timeout client 2m
    timeout server 2m

resolvers dns
    nameserver azure 168.63.129.16:53
    resolve_retries 3
    timeout resolve 5s
    timeout retry 1s
    hold valid 30s

frontend login_microsoftonline
    bind *:443
    default_backend entra_login

backend entra_login
    server login login.microsoftonline.com:443 check resolvers dns init-addr libc,none resolve-prefer ipv4
```

Point important : `resolve-prefer ipv4` a été nécessaire dans cette POC. Sans cette option, HAProxy résolvait parfois `login.microsoftonline.com` en IPv6 et les connexions échouaient dans le contexte réseau testé.

## Configuration Entra ID et APIM

La partie applicative utilisée pour l'invocation est le scénario Model Serving avec service principal, pas la managed identity Databricks.

Ressources Entra ID :

- application protégée APIM :
  - application/client ID : `5285960b-10d8-4a4f-b64e-26a9636d7451`
  - identifier URI : `api://495929eb-f078-464d-b6ef-e9fe18c31e12/dbxapimpoc-fwzds2-apim-api`
  - app role : `APIM.Proxy.Invoke`
- application cliente Model Serving :
  - client ID : `0bf51c32-c05b-4dfc-88e6-1bcfda9a60f5`
  - service principal associé
  - app role assignment vers l'API APIM protégée

Le serving endpoint obtient un token avec le flow OAuth2 `client_credentials` :

```text
POST https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/token
grant_type=client_credentials
client_id=<serving-client-id>
client_secret=<secret-in-databricks-secret-scope>
scope=api://<tenant-id>/<apim-api-name>/.default
```

APIM valide ensuite le JWT sur la route :

```text
https://dbxapimpocfwzds2apim.azure-api.net/openai/sp/chat/completions
```

La policy APIM vérifie :

- issuer Entra v2 du tenant
- audience JWT réelle : `5285960b-10d8-4a4f-b64e-26a9636d7451`
- claim `roles` contenant `APIM.Proxy.Invoke`
- claim `azp` correspondant au client ID du service principal Model Serving

APIM appelle ensuite Azure OpenAI avec sa propre managed identity :

```xml
<authentication-managed-identity resource="https://cognitiveservices.azure.com" />
```

## Configuration Databricks Model Serving

Le script de test `scripts/deploy-databricks-serving-sp-test.sh` a créé ou mis à jour les objets Databricks suivants :

- secret scope : `apim-openai-serving-sp`
- secret : `client-secret`
- notebook de registration :
  - `/Users/marc.milbled@gmail.com/register_apim_sp_serving_probe`
- job Databricks :
  - `poc-apim-openai-service-principal-serving-test`
- registered model Unity Catalog :
  - `dbxapimpoc_fwzds2_dbx.default.apim_sp_serving_probe`
- serving endpoint :
  - `apim-sp-serving-probe`

Variables d'environnement injectées dans le served entity :

- `TENANT_ID`
- `CLIENT_ID`
- `CLIENT_SECRET`
  - référence Databricks secret : `{{secrets/apim-openai-serving-sp/client-secret}}`
- `APIM_URL`
- `APIM_AUDIENCE`
  - ressource OAuth utilisée pour le scope `.default`

Le modèle Python MLflow fait ces étapes dans `predict()` :

1. lit le secret client injecté en variable d'environnement
2. appelle le token endpoint Entra ID
3. décode le JWT reçu pour exposer les claims utiles dans la réponse de test
4. appelle APIM avec `Authorization: Bearer <token>`
5. retourne le statut APIM et la réponse Azure OpenAI

## Configuration Databricks NCC

La configuration NCC est account-level, pas workspace-level.

Account ID utilisé pendant le test :

```text
c40e0133-b08f-4d33-b892-ea9052199bf3
```

Workspace Azure Databricks :

```text
workspace_id: 7405612619625468
workspace_url: adb-7405612619625468.8.azuredatabricks.net
region: francecentral
```

Le script `scripts/configure-databricks-login-proxy-ncc.sh` a fait les appels Accounts API suivants.

### 1. Obtention d'un token Databricks account API

Le script utilise un token AAD pour la ressource Databricks :

```bash
az account get-access-token \
  --resource 2ff814a6-3304-4ab8-85cb-cd0e6f879c1d
```

### 2. Création ou réutilisation de la NCC

Endpoint :

```text
GET /api/2.0/accounts/<account-id>/network-connectivity-configs
POST /api/2.0/accounts/<account-id>/network-connectivity-configs
```

Payload de création :

```json
{
  "name": "poc-login-proxy-ncc",
  "region": "francecentral"
}
```

NCC créée pendant le test :

```text
network_connectivity_config_id: aa966f14-655c-44b2-ad63-779edd30f283
name: poc-login-proxy-ncc
```

### 3. Création de la private endpoint rule

Endpoint :

```text
POST /api/2.0/accounts/<account-id>/network-connectivity-configs/<ncc-id>/private-endpoint-rules
```

Payload :

```json
{
  "domain_names": [
    "login.microsoftonline.com"
  ],
  "resource_id": "/subscriptions/636cafa7-3704-452b-bc87-3a11c9bde98a/resourceGroups/rg-dbxapimpoc-fwzds2/providers/Microsoft.Network/privateLinkServices/dbxapimpoc-fwzds2-login-proxy-pls"
}
```

Rule créée pendant le test :

```text
rule_id: b6749314-1dc3-443f-bdcf-633697d8e1e6
endpoint_name: databricks-aa966f14-655c-44b2-ad63-779edd30f283-pe-156003f4
connection_state: ESTABLISHED
```

Cette règle indique à Databricks serverless de connecter le domaine `login.microsoftonline.com` au Private Link Service fourni. C'est le point clé du test : le code du model serving continue d'appeler `https://login.microsoftonline.com`, mais le routage réseau côté Databricks est modifié par NCC.

### 4. Attachement de la NCC au workspace

Endpoint :

```text
PATCH /api/2.0/accounts/<account-id>/workspaces/<workspace-id>
```

Payload :

```json
{
  "network_connectivity_config_id": "aa966f14-655c-44b2-ad63-779edd30f283"
}
```

Le script attend ensuite que le workspace revienne en statut `RUNNING`.

### 5. Approbation Azure du private endpoint Databricks

Après création de la rule NCC, Azure a montré une connexion PLS entrante :

```text
name: databricks-aa966f14-655c-44b2-ad63-779edd30.7fc0e552-60de-42cf-95a5-763c1a9b77a1
private endpoint subscription: 973c7e63-fc1e-4dbf-a808-8ad3a5f5430f
status initial: Pending
```

Elle a été approuvée avec :

```bash
az network private-endpoint-connection approve \
  --id "<pls-id>/privateEndpointConnections/<connection-name>" \
  --description "Approved for Databricks NCC login.microsoftonline.com proxy POC"
```

Après approbation, la rule NCC est passée à :

```text
connection_state: ESTABLISHED
```

## Résultat fonctionnel

Invocation directe du serving endpoint après activation NCC :

```json
{
  "predictions": [
    {
      "status": 200,
      "auth_flow": "service_principal_client_credentials",
      "apim_url": "https://dbxapimpocfwzds2apim.azure-api.net/openai/sp/chat/completions",
      "apim_audience": "api://495929eb-f078-464d-b6ef-e9fe18c31e12/dbxapimpoc-fwzds2-apim-api",
      "token_aud": "5285960b-10d8-4a4f-b64e-26a9636d7451",
      "token_azp": "0bf51c32-c05b-4dfc-88e6-1bcfda9a60f5",
      "token_appid": null,
      "token_roles": [
        "APIM.Proxy.Invoke"
      ],
      "model_response": "sp-ok"
    }
  ]
}
```

Cela prouve que :

- le serving endpoint a obtenu un token Entra valide
- le token contient bien le rôle applicatif APIM attendu
- APIM a accepté le bearer token
- APIM a appelé Azure OpenAI avec sa managed identity
- Azure OpenAI a répondu au modèle derrière APIM

## Preuve réseau du passage par HAProxy

La preuve utile n'est pas un `curl` depuis la VM. Le test probant est une capture réseau sur la VM pendant une invocation du serving endpoint.

Commande utilisée sur la VM :

```bash
sudo timeout 75 tcpdump -nn -tttt -i any 'tcp port 443' -c 80
```

Extrait observé pendant l'invocation Model Serving :

```text
2026-06-08 16:16:22.755870 eth0 In  IP 10.80.2.4.1033 > 10.80.1.5.443: Flags [S]
2026-06-08 16:16:22.755921 eth0 Out IP 10.80.1.5.443 > 10.80.2.4.1033: Flags [S.]
2026-06-08 16:16:22.758190 eth0 Out IP 10.80.1.5.51070 > 20.190.160.64.443: Flags [S]
2026-06-08 16:16:22.768854 eth0 In  IP 20.190.160.64.443 > 10.80.1.5.51070: Flags [S.]
```

Lecture :

- `10.80.2.4 -> 10.80.1.5:443` : trafic entrant depuis le Private Link Service vers la VM HAProxy.
- `10.80.1.5 -> 20.190.160.64:443` : HAProxy ouvre une connexion sortante vers une IP Microsoft Entra pour `login.microsoftonline.com`.

Cette capture a été faite pendant que l'invocation serving retournait `status: 200` et `model_response: sp-ok`. C'est donc la preuve que l'appel token du serving endpoint passe bien par HAProxy.

## Points d'attention

- Ce design ne contourne pas l'authentification. Le service principal doit toujours obtenir un token Entra valide.
- HAProxy est en passthrough TCP. Il ne voit pas le contenu HTTP et ne termine pas TLS.
- Dans la POC, l'IP egress contrôlée est celle du NAT Gateway Azure : `20.216.128.52`.
- En environnement entreprise, le NAT Gateway Azure serait remplacé ou prolongé par l'egress corporate attendu afin de satisfaire les règles Conditional Access basées sur IP.
- L'IP source visible par Entra doit être validée dans les sign-in logs Entra du service principal pour une preuve complète côté IAM.
- La route NCC est account-level et régionale. Elle doit être attachée explicitement au workspace.
- Le test a été réalisé avec un service principal et secret Databricks. Il ne prouve pas que Model Serving supporte une managed identity native pour appeler APIM. Le test précédent a au contraire montré que le runtime Model Serving ne dispose pas des primitives UC service credentials utilisées en notebook/serverless job.

## Nettoyage manuel hors Terraform

Certains objets Databricks sont créés hors Terraform :

- serving endpoint `apim-sp-serving-probe`
- job `poc-apim-openai-service-principal-serving-test`
- notebook `/Users/<user>/register_apim_sp_serving_probe`
- secret scope `apim-openai-serving-sp`
- registered model `dbxapimpoc_fwzds2_dbx.default.apim_sp_serving_probe`
- NCC `poc-login-proxy-ncc`
- private endpoint rule `b6749314-1dc3-443f-bdcf-633697d8e1e6`
- attachement NCC du workspace

Ces objets doivent être supprimés avant ou pendant le teardown de la POC. La NCC rule doit idéalement être supprimée avant le `terraform destroy`, car elle maintient une connexion private endpoint vers le Private Link Service Azure.
