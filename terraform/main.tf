data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 6
  lower   = true
  upper   = false
  numeric = true
  special = false
}

resource "random_uuid" "apim_app_role" {}

locals {
  suffix                    = random_string.suffix.result
  base_name                 = "${var.name_prefix}-${local.suffix}"
  compact_prefix            = substr(replace(var.name_prefix, "-", ""), 0, 12)
  resource_group_name       = "rg-${local.base_name}"
  databricks_workspace_name = substr("${local.compact_prefix}-${local.suffix}-dbx", 0, 64)
  databricks_mrg_name       = "rg-${local.base_name}-dbx-managed"
  access_connector_name     = "${local.base_name}-ac"
  apim_name                 = substr(replace("${local.compact_prefix}${local.suffix}apim", "-", ""), 0, 50)
  apim_api_name             = "openai-proxy"
  apim_api_path             = "openai"
  openai_account_name       = substr(replace("${local.compact_prefix}${local.suffix}aoai", "-", ""), 0, 24)
  openai_custom_subdomain   = substr(replace("${var.openai_custom_subdomain_prefix}${local.suffix}", "-", ""), 0, 63)
  apim_api_identifier_uri   = "api://${var.tenant_id}/${local.base_name}-apim-api"
  jwt_openid_config_url     = "https://login.microsoftonline.com/${var.tenant_id}/v2.0/.well-known/openid-configuration"
  jwt_v1_issuer             = "https://sts.windows.net/${var.tenant_id}/"
  openai_resource_audience  = "https://cognitiveservices.azure.com"
  apim_jwt_audience         = local.openai_resource_audience
  openai_backend_base_url   = "https://${local.openai_custom_subdomain}.openai.azure.com"
  effective_tags            = merge(var.tags, { scenario = "databricks-serverless-apim-openai-mi" })
}

resource "azurerm_resource_group" "this" {
  name     = local.resource_group_name
  location = var.location
  tags     = local.effective_tags
}

resource "azurerm_databricks_workspace" "this" {
  name                          = local.databricks_workspace_name
  resource_group_name           = azurerm_resource_group.this.name
  location                      = azurerm_resource_group.this.location
  sku                           = var.databricks_sku
  managed_resource_group_name   = local.databricks_mrg_name
  public_network_access_enabled = var.enable_databricks_public_network_access
  tags                          = local.effective_tags
}

resource "azurerm_databricks_access_connector" "this" {
  name                = local.access_connector_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.effective_tags

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_cognitive_account" "openai" {
  name                          = local.openai_account_name
  resource_group_name           = azurerm_resource_group.this.name
  location                      = var.openai_location
  kind                          = "OpenAI"
  sku_name                      = "S0"
  custom_subdomain_name         = local.openai_custom_subdomain
  local_auth_enabled            = false
  public_network_access_enabled = true
  tags                          = local.effective_tags
}

resource "azurerm_cognitive_deployment" "model" {
  count                = var.create_model_deployment ? 1 : 0
  name                 = var.openai_model_deployment_name
  cognitive_account_id = azurerm_cognitive_account.openai.id

  model {
    format  = var.openai_model_format
    name    = var.openai_model_name
    version = var.openai_model_version
  }

  sku {
    name     = "Standard"
    capacity = 1
  }
}

resource "azurerm_api_management" "this" {
  name                = local.apim_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  publisher_name      = var.publisher_name
  publisher_email     = var.publisher_email
  sku_name            = var.apim_sku_name
  tags                = local.effective_tags

  identity {
    type = "SystemAssigned"
  }
}

resource "azuread_application" "apim_api" {
  display_name     = "${local.base_name}-apim-api"
  sign_in_audience = "AzureADMyOrg"
  identifier_uris  = [local.apim_api_identifier_uri]
  owners           = [data.azurerm_client_config.current.object_id]

  app_role {
    allowed_member_types = ["Application"]
    description          = "Call the APIM protected OpenAI proxy."
    display_name         = "APIM.Proxy.Invoke"
    id                   = random_uuid.apim_app_role.result
    enabled              = true
    value                = "APIM.Proxy.Invoke"
  }
}

resource "azuread_service_principal" "apim_api" {
  client_id                    = azuread_application.apim_api.client_id
  app_role_assignment_required = true
  owners                       = [data.azurerm_client_config.current.object_id]
}

resource "azuread_app_role_assignment" "databricks_access_connector_to_apim_api" {
  app_role_id         = random_uuid.apim_app_role.result
  principal_object_id = azurerm_databricks_access_connector.this.identity[0].principal_id
  resource_object_id  = azuread_service_principal.apim_api.object_id
}

resource "azurerm_role_assignment" "apim_openai_user" {
  scope                = azurerm_cognitive_account.openai.id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_api_management.this.identity[0].principal_id
}

resource "azurerm_api_management_api" "openai_proxy" {
  name                  = local.apim_api_name
  resource_group_name   = azurerm_resource_group.this.name
  api_management_name   = azurerm_api_management.this.name
  revision              = "1"
  display_name          = "OpenAI Proxy"
  path                  = local.apim_api_path
  protocols             = ["https"]
  subscription_required = false
}

resource "azurerm_api_management_api_operation" "chat_completions" {
  operation_id        = "chat-completions"
  api_name            = azurerm_api_management_api.openai_proxy.name
  api_management_name = azurerm_api_management.this.name
  resource_group_name = azurerm_resource_group.this.name
  display_name        = "Chat Completions"
  method              = "POST"
  url_template        = "/chat/completions"
  description         = "Proxy a chat completions request to Azure OpenAI using APIM managed identity."

  request {
    description = "OpenAI-compatible chat completions payload."
    representation {
      content_type = "application/json"
    }
  }

  response {
    status_code = 200
    description = "Successful response from Azure OpenAI."
    representation {
      content_type = "application/json"
    }
  }
}

resource "azurerm_api_management_api_policy" "openai_proxy" {
  api_name            = azurerm_api_management_api.openai_proxy.name
  api_management_name = azurerm_api_management.this.name
  resource_group_name = azurerm_resource_group.this.name

  xml_content = <<-XML
    <policies>
      <inbound>
        <base />
        <validate-jwt header-name="Authorization" require-scheme="Bearer" failed-validation-httpcode="401" failed-validation-error-message="Missing or invalid bearer token.">
          <openid-config url="${local.jwt_openid_config_url}" />
          <audiences>
            <audience>${local.apim_jwt_audience}</audience>
          </audiences>
          <issuers>
            <issuer>${local.jwt_v1_issuer}</issuer>
          </issuers>
          <required-claims>
            <claim name="oid" match="any">
              <value>${azurerm_databricks_access_connector.this.identity[0].principal_id}</value>
            </claim>
          </required-claims>
        </validate-jwt>
        <set-backend-service base-url="${local.openai_backend_base_url}" />
        <rewrite-uri template="/openai/deployments/${var.openai_model_deployment_name}/chat/completions?api-version=${var.openai_api_version}" copy-unmatched-params="false" />
        <authentication-managed-identity resource="${local.openai_resource_audience}" />
        <set-header name="Content-Type" exists-action="override">
          <value>application/json</value>
        </set-header>
      </inbound>
      <backend>
        <base />
      </backend>
      <outbound>
        <base />
      </outbound>
      <on-error>
        <base />
      </on-error>
    </policies>
  XML

  depends_on = [
    azurerm_role_assignment.apim_openai_user,
    azuread_app_role_assignment.databricks_access_connector_to_apim_api,
  ]
}
