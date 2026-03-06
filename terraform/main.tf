terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

# -------------------------------------------------------------------
# RESOURCE GROUP
# -------------------------------------------------------------------
resource "azurerm_resource_group" "rg" {
  name     = "${var.prefix}-rg"
  location = var.location
}

# -------------------------------------------------------------------
# AZURE KEY VAULT (secrets management)
# -------------------------------------------------------------------
data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "kv" {
  name                       = "${replace(var.prefix, "-", "")}kv${substr(data.azurerm_client_config.current.subscription_id, 0, 8)}"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "premium"
  purge_protection_enabled   = true
  soft_delete_retention_days = 7

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id

    key_permissions    = ["Get", "List", "Create", "Update", "Delete"]
    secret_permissions = ["Get", "List", "Set", "Delete"]
  }
}

resource "azurerm_key_vault_secret" "sql_password" {
  name         = "sql-admin-password"
  value        = var.sql_admin_password
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [azurerm_key_vault.kv]
}

resource "azurerm_key_vault_secret" "grafana_password" {
  name         = "grafana-admin-password"
  value        = var.grafana_password
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [azurerm_key_vault.kv]
}

# -------------------------------------------------------------------
# STORAGE ACCOUNT
# -------------------------------------------------------------------
resource "azurerm_storage_account" "sa" {
  name                     = "${var.prefix}storage001"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_container" "raw" {
  name                  = "raw-f1-data"
  storage_account_name  = azurerm_storage_account.sa.name
  container_access_type = "private"
}

# Public container so AKS pods can download scripts
resource "azurerm_storage_container" "scripts" {
  name                  = "scripts"
  storage_account_name  = azurerm_storage_account.sa.name
  container_access_type = "blob"
}

# Upload race day producer script
resource "azurerm_storage_blob" "producer_race_script" {
  name                   = "producer_race.py"
  storage_account_name   = azurerm_storage_account.sa.name
  storage_container_name = azurerm_storage_container.scripts.name
  type                   = "Block"
  source                 = "producer_race.py"
}

# -------------------------------------------------------------------
# EVENT HUBS (Kafka)
# -------------------------------------------------------------------
resource "azurerm_eventhub_namespace" "kafka" {
  name                = "${var.prefix}-eventhub"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "Standard"
  capacity            = 1
}

resource "azurerm_eventhub" "positions" {
  name                = "f1-positions"
  namespace_name      = azurerm_eventhub_namespace.kafka.name
  resource_group_name = azurerm_resource_group.rg.name
  partition_count     = 4
  message_retention   = 1
}

resource "azurerm_eventhub" "laps" {
  name                = "f1-laps"
  namespace_name      = azurerm_eventhub_namespace.kafka.name
  resource_group_name = azurerm_resource_group.rg.name
  partition_count     = 4
  message_retention   = 1
}

resource "azurerm_eventhub" "telemetry" {
  name                = "f1-telemetry"
  namespace_name      = azurerm_eventhub_namespace.kafka.name
  resource_group_name = azurerm_resource_group.rg.name
  partition_count     = 4
  message_retention   = 1
}

resource "azurerm_eventhub" "weather" {
  name                = "f1-weather"
  namespace_name      = azurerm_eventhub_namespace.kafka.name
  resource_group_name = azurerm_resource_group.rg.name
  partition_count     = 2
  message_retention   = 1
}

resource "azurerm_eventhub_namespace_authorization_rule" "producer" {
  name                = "producer-rule"
  namespace_name      = azurerm_eventhub_namespace.kafka.name
  resource_group_name = azurerm_resource_group.rg.name
  listen              = true
  send                = true
  manage              = false
}

# -------------------------------------------------------------------
# AZURE SQL (for Grafana to query)
# -------------------------------------------------------------------
resource "azurerm_mssql_server" "sql" {
  name                         = "${var.prefix}-sqlserver-${replace(lower(var.sql_location), " ", "")}"
  resource_group_name          = azurerm_resource_group.rg.name
  location                     = var.sql_location
  version                      = "12.0"
  administrator_login          = var.sql_admin_login
  administrator_login_password = var.sql_admin_password
}

resource "azurerm_mssql_database" "db" {
  name                        = "f1db"
  server_id                   = azurerm_mssql_server.sql.id
  sku_name                    = "GP_S_Gen5_1"  # Serverless
  min_capacity                = 0.5
  max_size_gb                 = 32
  auto_pause_delay_in_minutes = 60  # auto-pause after 60 min of inactivity
}

resource "azurerm_mssql_firewall_rule" "allow_azure" {
  name             = "AllowAzureServices"
  server_id        = azurerm_mssql_server.sql.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

# -------------------------------------------------------------------
# STREAM ANALYTICS (Event Hubs → SQL)
# -------------------------------------------------------------------
resource "azurerm_stream_analytics_job" "analytics" {
  name                                     = "${var.prefix}-analytics"
  resource_group_name                      = azurerm_resource_group.rg.name
  location                                 = azurerm_resource_group.rg.location
  compatibility_level                      = "1.2"
  data_locale                              = "en-GB"
  events_late_arrival_max_delay_in_seconds = 60
  events_out_of_order_max_delay_in_seconds = 50
  events_out_of_order_policy               = "Adjust"
  output_error_policy                      = "Drop"
  streaming_units                          = 1

  transformation_query = <<QUERY
    SELECT session_key, driver_number, position, date, System.Timestamp() AS processed_at
    INTO [sql-positions-output]
    FROM [eventhub-positions-input]

    SELECT session_key, driver_number, lap_number, lap_duration, date_start, System.Timestamp() AS processed_at
    INTO [sql-laps-output]
    FROM [eventhub-laps-input]

    SELECT session_key, driver_number, speed, rpm, throttle, brake, date, System.Timestamp() AS processed_at
    INTO [sql-telemetry-output]
    FROM [eventhub-telemetry-input]

    SELECT session_key, air_temperature, humidity, pressure, rainfall, wind_speed, date, System.Timestamp() AS processed_at
    INTO [sql-weather-output]
    FROM [eventhub-weather-input]
  QUERY
}

# -------------------------------------------------------------------
# ACI: GRAFANA (always on - public dashboard)
# -------------------------------------------------------------------
resource "azurerm_container_group" "grafana" {
  name                = "${var.prefix}-grafana"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  os_type             = "Linux"
  restart_policy      = "Always"
  ip_address_type     = "Public"
  dns_name_label      = "${var.prefix}-grafana-dashboard"

  container {
    name   = "grafana"
    image  = "grafana/grafana:latest"
    cpu    = "0.5"
    memory = "1"

    ports {
      port     = 3000
      protocol = "TCP"
    }

    environment_variables = {
      GF_SECURITY_ADMIN_PASSWORD = var.grafana_password
      GF_INSTALL_PLUGINS         = "grafana-clock-panel"
    }
  }
}

# -------------------------------------------------------------------
# NETWORKING FOR AKS
# -------------------------------------------------------------------
resource "azurerm_virtual_network" "vnet" {
  name                = "${var.prefix}-vnet"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "aks_subnet" {
  name                 = "aks-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# -------------------------------------------------------------------
# AKS CLUSTER (race day only - start/stop manually)
# Start:  az aks start --name openf1-aks --resource-group openf1-rg
# Stop:   az aks stop  --name openf1-aks --resource-group openf1-rg
# -------------------------------------------------------------------
resource "azurerm_kubernetes_cluster" "aks" {
  name                = "${var.prefix}-aks"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = "${var.prefix}-aks"

  default_node_pool {
    name                = "default"
    node_count          = 1
    vm_size             = "standard_dc2ads_v5"
    enable_auto_scaling = true
    min_count           = 1
    max_count           = 5
    vnet_subnet_id      = azurerm_subnet.aks_subnet.id
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin = "azure"
    dns_service_ip = "10.0.2.10"
    service_cidr   = "10.0.2.0/24"
  }

  tags = {
    environment = "race-day"
    project     = "openf1"
  }
}
