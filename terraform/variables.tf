variable "subscription_id" {
  description = "ID de l'abonnement Azure cible."
  type        = string
}

variable "tenant_id" {
  description = "ID du tenant Microsoft Entra cible."
  type        = string
}

variable "location" {
  description = "Région Azure pour APIM et Databricks. Choisir une région supportant les services requis."
  type        = string
  default     = "francecentral"
}

variable "openai_location" {
  description = "Région Azure OpenAI. Peut être différente de location si nécessaire."
  type        = string
  default     = "swedencentral"
}

variable "name_prefix" {
  description = "Préfixe lisible pour nommer les ressources."
  type        = string
  default     = "dbxapimpoc"
}

variable "databricks_sku" {
  description = "SKU du workspace Databricks."
  type        = string
  default     = "premium"
}

variable "apim_sku_name" {
  description = "SKU APIM. Consumption est le moins cher pour une POC éphémère."
  type        = string
  default     = "Consumption_0"
}

variable "publisher_name" {
  description = "Nom du publisher APIM."
  type        = string
  default     = "Platform Engineering"
}

variable "publisher_email" {
  description = "Email du publisher APIM."
  type        = string
}

variable "openai_custom_subdomain_prefix" {
  description = "Préfixe globalement unique pour le custom subdomain Azure OpenAI. Le suffixe aléatoire est ajouté automatiquement."
  type        = string
  default     = "dbxapimpocaoai"
}

variable "openai_model_deployment_name" {
  description = "Nom logique du déploiement de modèle Azure OpenAI."
  type        = string
  default     = "gpt-4o-mini"
}

variable "openai_model_name" {
  description = "Nom du modèle Azure OpenAI à déployer."
  type        = string
  default     = "gpt-4o-mini"
}

variable "openai_model_version" {
  description = "Version du modèle Azure OpenAI. Laisser vide si Azure choisit la version par défaut du modèle."
  type        = string
  default     = ""
}

variable "openai_model_format" {
  description = "Format du modèle Azure OpenAI."
  type        = string
  default     = "OpenAI"
}

variable "openai_api_version" {
  description = "Version d'API utilisée par APIM pour appeler Azure OpenAI."
  type        = string
  default     = "2024-10-21"
}

variable "create_model_deployment" {
  description = "Créer ou non un déploiement de modèle Azure OpenAI."
  type        = bool
  default     = false
}

variable "enable_databricks_public_network_access" {
  description = "Activer l'accès public au control plane Databricks pour simplifier la POC."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags à appliquer aux ressources Azure."
  type        = map(string)
  default = {
    workload = "poc-databricks-apim-openai"
    owner    = "platform-engineering"
  }
}
