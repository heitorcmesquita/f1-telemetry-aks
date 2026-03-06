output "grafana_url" {
  value       = "http://${azurerm_container_group.grafana.fqdn}:3000"
  description = "Grafana dashboard URL - open this in your browser"
}

output "grafana_password" {
  value     = var.grafana_password
  sensitive = true
}

output "sql_server_fqdn" {
  value       = azurerm_mssql_server.sql.fully_qualified_domain_name
  description = "SQL Server address - use this in Grafana datasource"
}

output "eventhub_connection_string" {
  value     = azurerm_eventhub_namespace_authorization_rule.producer.primary_connection_string
  sensitive = true
}

output "storage_account_name" {
  value = azurerm_storage_account.sa.name
}

output "producer_race_script_url" {
  value       = azurerm_storage_blob.producer_race_script.url
  description = "URL of the race day producer script in Blob Storage"
}

output "aks_cluster_name" {
  value       = azurerm_kubernetes_cluster.aks.name
  description = "AKS cluster name - start this on race day"
}

output "aks_start_command" {
  value       = "az aks start --name ${azurerm_kubernetes_cluster.aks.name} --resource-group ${azurerm_resource_group.rg.name}"
  description = "Run this command to start AKS on race day"
}

output "aks_stop_command" {
  value       = "az aks stop --name ${azurerm_kubernetes_cluster.aks.name} --resource-group ${azurerm_resource_group.rg.name}"
  description = "Run this command to stop AKS after the race"
}

output "key_vault_name" {
  value = azurerm_key_vault.kv.name
}
