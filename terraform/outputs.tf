output "resource_group_name" {
  description = "Nom du resource group de la POC."
  value       = azurerm_resource_group.this.name
}

output "databricks_workspace_name" {
  description = "Nom du workspace Azure Databricks."
  value       = azurerm_databricks_workspace.this.name
}

output "databricks_workspace_url" {
  description = "URL du workspace Azure Databricks."
  value       = azurerm_databricks_workspace.this.workspace_url
}

output "databricks_access_connector_id" {
  description = "ID de l'Access Connector Databricks à lier à une Unity Catalog service credential."
  value       = azurerm_databricks_access_connector.this.id
}

output "databricks_access_connector_principal_id" {
  description = "Principal ID de la managed identity portée par l'Access Connector."
  value       = azurerm_databricks_access_connector.this.identity[0].principal_id
}

output "apim_gateway_url" {
  description = "URL de base du gateway APIM."
  value       = azurerm_api_management.this.gateway_url
}

output "apim_openai_chat_completions_url" {
  description = "URL cible pour le test d'appel APIM vers Azure OpenAI."
  value       = "${azurerm_api_management.this.gateway_url}/${local.apim_api_path}/chat/completions"
}

output "apim_protected_api_application_id" {
  description = "Client ID de l'application Entra protégée par APIM. Sert d'audience logique pour le token."
  value       = azuread_application.apim_api.client_id
}

output "apim_protected_api_identifier_uri" {
  description = "Identifier URI de l'application Entra créée pour la variante app-role."
  value       = local.apim_api_identifier_uri
}

output "apim_jwt_audience" {
  description = "Audience attendue par APIM dans le jeton bearer de la managed identity Databricks."
  value       = local.apim_jwt_audience
}

output "azure_openai_account_name" {
  description = "Nom du compte Azure OpenAI."
  value       = azurerm_cognitive_account.openai.name
}

output "azure_openai_endpoint" {
  description = "Endpoint Azure OpenAI ciblé par APIM."
  value       = azurerm_cognitive_account.openai.endpoint
}

output "manual_next_steps" {
  description = "Rappel synthétique des actions manuelles après apply."
  value = [
    "1. Vérifier que le modèle ${var.openai_model_deployment_name} existe si create_model_deployment=false.",
    "2. Dans Databricks, créer une Unity Catalog service credential qui pointe vers l'Access Connector ${azurerm_databricks_access_connector.this.id}.",
    "3. Depuis un notebook serverless, utiliser cette service credential pour obtenir un jeton pour l'audience ${local.apim_jwt_audience}.",
    "4. Appeler ${azurerm_api_management.this.gateway_url}/${local.apim_api_path}/chat/completions avec ce bearer token.",
    "5. Détruire la POC avec terraform destroy dès la validation terminée."
  ]
}
