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
  jwt_v2_issuer             = "https://login.microsoftonline.com/${var.tenant_id}/v2.0"
  openai_resource_audience  = "https://cognitiveservices.azure.com"
  apim_jwt_audience         = local.openai_resource_audience
  apim_sp_token_resource    = local.apim_api_identifier_uri
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

  api {
    requested_access_token_version = 2
  }

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

resource "azuread_application" "serving_client" {
  display_name     = "${local.base_name}-serving-client"
  sign_in_audience = "AzureADMyOrg"
  owners           = [data.azurerm_client_config.current.object_id]
}

resource "azuread_service_principal" "serving_client" {
  client_id = azuread_application.serving_client.client_id
  owners    = [data.azurerm_client_config.current.object_id]
}

resource "azuread_app_role_assignment" "databricks_access_connector_to_apim_api" {
  app_role_id         = random_uuid.apim_app_role.result
  principal_object_id = azurerm_databricks_access_connector.this.identity[0].principal_id
  resource_object_id  = azuread_service_principal.apim_api.object_id
}

resource "azuread_app_role_assignment" "serving_client_to_apim_api" {
  app_role_id         = random_uuid.apim_app_role.result
  principal_object_id = azuread_service_principal.serving_client.object_id
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

resource "azurerm_api_management_api_operation" "chat_completions_sp" {
  operation_id        = "chat-completions-sp"
  api_name            = azurerm_api_management_api.openai_proxy.name
  api_management_name = azurerm_api_management.this.name
  resource_group_name = azurerm_resource_group.this.name
  display_name        = "Chat Completions Service Principal"
  method              = "POST"
  url_template        = "/sp/chat/completions"
  description         = "Proxy a chat completions request to Azure OpenAI using a service-principal-authenticated Model Serving caller."

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

resource "azurerm_api_management_api_operation_policy" "openai_proxy_mi" {
  api_name            = azurerm_api_management_api.openai_proxy.name
  api_management_name = azurerm_api_management.this.name
  operation_id        = azurerm_api_management_api_operation.chat_completions.operation_id
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

resource "azurerm_api_management_api_operation_policy" "openai_proxy_sp" {
  api_name            = azurerm_api_management_api.openai_proxy.name
  api_management_name = azurerm_api_management.this.name
  operation_id        = azurerm_api_management_api_operation.chat_completions_sp.operation_id
  resource_group_name = azurerm_resource_group.this.name

  xml_content = <<-XML
    <policies>
      <inbound>
        <base />
        <validate-jwt header-name="Authorization" require-scheme="Bearer" failed-validation-httpcode="401" failed-validation-error-message="Missing or invalid bearer token.">
          <openid-config url="${local.jwt_openid_config_url}" />
          <audiences>
            <audience>${azuread_application.apim_api.client_id}</audience>
          </audiences>
          <issuers>
            <issuer>${local.jwt_v2_issuer}</issuer>
          </issuers>
          <required-claims>
            <claim name="roles" match="any">
              <value>APIM.Proxy.Invoke</value>
            </claim>
            <claim name="azp" match="any">
              <value>${azuread_application.serving_client.client_id}</value>
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
    azuread_app_role_assignment.serving_client_to_apim_api,
  ]
}

resource "tls_private_key" "login_proxy" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "azurerm_virtual_network" "login_proxy" {
  name                = "${local.base_name}-login-proxy-vnet"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  address_space       = ["10.80.0.0/16"]
  tags                = local.effective_tags
}

resource "azurerm_subnet" "login_proxy_vm" {
  name                 = "snet-login-proxy-vm"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.login_proxy.name
  address_prefixes     = ["10.80.1.0/24"]
}

resource "azurerm_subnet" "login_proxy_pls" {
  name                                          = "snet-login-proxy-pls"
  resource_group_name                           = azurerm_resource_group.this.name
  virtual_network_name                          = azurerm_virtual_network.login_proxy.name
  address_prefixes                              = ["10.80.2.0/24"]
  private_link_service_network_policies_enabled = false
}

resource "azurerm_network_security_group" "login_proxy" {
  name                = "${local.base_name}-login-proxy-nsg"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.effective_tags

  security_rule {
    name                       = "AllowTcp443FromVnet"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "login_proxy_vm" {
  subnet_id                 = azurerm_subnet.login_proxy_vm.id
  network_security_group_id = azurerm_network_security_group.login_proxy.id
}

resource "azurerm_public_ip" "login_proxy_nat" {
  name                = "${local.base_name}-login-proxy-nat-pip"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.effective_tags
}

resource "azurerm_nat_gateway" "login_proxy" {
  name                    = "${local.base_name}-login-proxy-nat"
  resource_group_name     = azurerm_resource_group.this.name
  location                = azurerm_resource_group.this.location
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10
  tags                    = local.effective_tags
}

resource "azurerm_nat_gateway_public_ip_association" "login_proxy" {
  nat_gateway_id       = azurerm_nat_gateway.login_proxy.id
  public_ip_address_id = azurerm_public_ip.login_proxy_nat.id
}

resource "azurerm_subnet_nat_gateway_association" "login_proxy_vm" {
  subnet_id      = azurerm_subnet.login_proxy_vm.id
  nat_gateway_id = azurerm_nat_gateway.login_proxy.id
}

resource "azurerm_network_interface" "login_proxy" {
  name                = "${local.base_name}-login-proxy-nic"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.effective_tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.login_proxy_vm.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "login_proxy" {
  name                = "${local.compact_prefix}${local.suffix}lpvm"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  size                = "Standard_B1s"
  admin_username      = "azureuser"
  network_interface_ids = [
    azurerm_network_interface.login_proxy.id,
  ]
  tags = local.effective_tags

  admin_ssh_key {
    username   = "azureuser"
    public_key = tls_private_key.login_proxy.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  custom_data = base64encode(<<-CLOUD_INIT
    #cloud-config
    package_update: true
    packages:
      - haproxy
    write_files:
      - path: /etc/haproxy/haproxy.cfg
        owner: root:root
        permissions: '0644'
        content: |
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
    runcmd:
      - systemctl enable haproxy
      - systemctl restart haproxy
  CLOUD_INIT
  )
}

resource "azurerm_lb" "login_proxy" {
  name                = "${local.base_name}-login-proxy-lb"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "Standard"
  tags                = local.effective_tags

  frontend_ip_configuration {
    name                          = "login-proxy-frontend"
    subnet_id                     = azurerm_subnet.login_proxy_vm.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_lb_backend_address_pool" "login_proxy" {
  name            = "login-proxy-backend"
  loadbalancer_id = azurerm_lb.login_proxy.id
}

resource "azurerm_network_interface_backend_address_pool_association" "login_proxy" {
  network_interface_id    = azurerm_network_interface.login_proxy.id
  ip_configuration_name   = "ipconfig1"
  backend_address_pool_id = azurerm_lb_backend_address_pool.login_proxy.id
}

resource "azurerm_lb_probe" "login_proxy" {
  name            = "tcp-443"
  loadbalancer_id = azurerm_lb.login_proxy.id
  protocol        = "Tcp"
  port            = 443
}

resource "azurerm_lb_rule" "login_proxy" {
  name                           = "tcp-443"
  loadbalancer_id                = azurerm_lb.login_proxy.id
  protocol                       = "Tcp"
  frontend_port                  = 443
  backend_port                   = 443
  frontend_ip_configuration_name = "login-proxy-frontend"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.login_proxy.id]
  probe_id                       = azurerm_lb_probe.login_proxy.id
}

resource "azurerm_private_link_service" "login_proxy" {
  name                = "${local.base_name}-login-proxy-pls"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.effective_tags

  load_balancer_frontend_ip_configuration_ids = [
    azurerm_lb.login_proxy.frontend_ip_configuration[0].id,
  ]

  nat_ip_configuration {
    name      = "primary"
    primary   = true
    subnet_id = azurerm_subnet.login_proxy_pls.id
  }

  auto_approval_subscription_ids = [var.subscription_id]
  visibility_subscription_ids    = [var.subscription_id]
}
