# Compte rendu POC

## Ce qui a été livré

Une base Terraform détruisible rapidement pour une POC `Databricks serverless -> APIM -> Azure OpenAI` avec authentification par managed identity :

- workspace Azure Databricks
- Databricks Access Connector avec managed identity
- Azure API Management avec managed identity
- compte Azure OpenAI sans clé locale
- application Microsoft Entra protégée pour servir d'audience APIM
- rôle applicatif `APIM.Proxy.Invoke` assigné à l'identité du Databricks Access Connector
- policy APIM qui :
  - valide le bearer token Entra
  - exige le rôle `APIM.Proxy.Invoke`
  - appelle Azure OpenAI avec la managed identity d'APIM

## Ce que la POC démontre

- une identité managée portée par Databricks peut obtenir un jeton Entra pour une API protégée
- APIM peut valider ce jeton comme point de contrôle
- APIM peut relayer vers Azure OpenAI sans secret applicatif, uniquement avec sa propre managed identity

## Ce qui reste manuel

- créer la `service credential` Unity Catalog dans Databricks
- lancer le notebook serverless de test
- vérifier qu'un déploiement Azure OpenAI existe si `create_model_deployment=false`

## Fichiers principaux

- [README.md](/home/marc/poc-databricks-apim-openai/README.md)
- [main.tf](/home/marc/poc-databricks-apim-openai/terraform/main.tf)
- [variables.tf](/home/marc/poc-databricks-apim-openai/terraform/variables.tf)
- [outputs.tf](/home/marc/poc-databricks-apim-openai/terraform/outputs.tf)
- [terraform.tfvars.example](/home/marc/poc-databricks-apim-openai/terraform/terraform.tfvars.example)

## Hypothèses et risques

- la POC est `single-tenant`
- le modèle Azure OpenAI demandé doit être disponible dans la région choisie
- j'ai exécuté `terraform init` et `terraform validate`, mais ils sont bloqués ici par la sandbox locale: accès DNS interdit vers `registry.terraform.io` puis interdiction `setsockopt` sur les sockets Unix des plugins Terraform
- la partie Databricks `service credential` dépend de l'activation Unity Catalog et des permissions de l'espace de travail

## Commandes prévues

```bash
cd /home/marc/poc-databricks-apim-openai/terraform
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan
terraform apply
terraform destroy
```
