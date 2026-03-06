variable "location" {
  default = "East US"
}

variable "sql_location" {
  default     = "Brazil South"
  description = "Region for SQL Server - East US has provisioning restrictions"
}

variable "prefix" {
  default = "openf1"
}

variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "sql_admin_login" {
  description = "SQL Server admin username"
  type        = string
  default     = "openf1admin"
}

variable "sql_admin_password" {
  description = "SQL Server admin password"
  type        = string
  sensitive   = true
}

variable "grafana_password" {
  description = "Grafana admin password"
  type        = string
  sensitive   = true
}
