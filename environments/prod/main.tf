terraform {
  backend "azurerm" {
    resource_group_name  = "backuprg"
    storage_account_name = "backupstorge"
    container_name       = "backupcontainer1254"
    key                  = "prod.terraform.tfstate"
  }
}

# Data sources
data "azurerm_client_config" "current" {}

# Local values
locals {
  common_tags = {
    "ManagedBy"   = "Terraform"
    "Owner"       = "TodoAppTeam"
    "Environment" = "prod"
    "Project"     = "TodoApp"
  }
  
  # Naming convention
  name_prefix = "todo-prod"
  location    = "East US 2"
}

# Resource Group
module "resource_group" {
  source = "../../modules/azurerm_resource_group"
  
  resource_group_name = "${local.name_prefix}-rg"
  location           = local.location
  tags               = local.common_tags
}

# Virtual Network
module "virtual_network" {
  source = "../../modules/azurerm_virtual_network"
  
  vnet_name          = "${local.name_prefix}-vnet"
  location           = local.location
  resource_group_name = module.resource_group.resource_group_name
  address_space      = ["10.1.0.0/16"]
  
  subnets = {
    "aks-subnet" = {
      address_prefixes = ["10.1.1.0/24"]
      service_endpoints = ["Microsoft.Storage", "Microsoft.KeyVault"]
      security_rules = [
        {
          name                       = "AllowHTTPS"
          priority                   = 100
          direction                  = "Inbound"
          access                     = "Allow"
          protocol                   = "Tcp"
          source_port_range          = "*"
          destination_port_range     = "443"
          source_address_prefix      = "10.1.0.0/16"
          destination_address_prefix = "*"
        },
        {
          name                       = "AllowHTTP"
          priority                   = 110
          direction                  = "Inbound"
          access                     = "Allow"
          protocol                   = "Tcp"
          source_port_range          = "*"
          destination_port_range     = "80"
          source_address_prefix      = "10.1.0.0/16"
          destination_address_prefix = "*"
        }
      ]
    }
    "sql-subnet" = {
      address_prefixes = ["10.1.2.0/24"]
      service_endpoints = ["Microsoft.Storage", "Microsoft.KeyVault"]
    }
  }
  
  tags = local.common_tags
}

# Azure Key Vault
module "key_vault" {
  source = "../../modules/azurerm_key_vault"
  
  key_vault_name      = "${local.name_prefix}-kv"
  location            = local.location
  resource_group_name = module.resource_group.resource_group_name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  object_id           = data.azurerm_client_config.current.object_id
  sku_name            = "premium"
  
  purge_protection_enabled = true
  soft_delete_retention_days = 30
  
  network_acls_default_action = "Deny"
  network_acls_bypass         = "AzureServices"
  virtual_network_subnet_ids  = [module.virtual_network.subnet_ids["aks-subnet"]]
  
  secrets = {
    "sql-admin-username" = {
      value = "todoappadmin"
      content_type = "text/plain"
      expiration_date = "2025-12-31T23:59:59Z"
    }
    "sql-admin-password" = {
      value = "TodoAppProd2024!"
      content_type = "text/plain"
      expiration_date = "2025-12-31T23:59:59Z"
    }
  }
  
  tags = local.common_tags
}

# Storage Account
module "storage_account" {
  source = "../../modules/azurerm_storage_account"
  
  storage_account_name   = lower(replace("${local.name_prefix}stg${random_string.stg_suffix.result}", "-", ""))
  resource_group_name    = module.resource_group.resource_group_name
  location              = local.location
  account_tier          = "Standard"
  account_replication_type = "GRS"
  min_tls_version       = "TLS1_2"
  allow_nested_items_to_be_public = false
  
  tags = local.common_tags
}

# Random string for globally unique storage account name
resource "random_string" "stg_suffix" {
  length  = 6
  upper   = false
  lower   = true
  numeric = true
  special = false
}

# SQL Server
module "sql_server" {
  source = "../../modules/azurerm_sql_server"
  
  sql_server_name = "${local.name_prefix}-sql-${random_string.stg_suffix.result}"
  rg_name         = module.resource_group.resource_group_name
  location        = local.location
  admin_username  = "todoappadmin"
  admin_password  = "TodoAppProd2024!"
  
  audit_storage_endpoint = module.storage_account.primary_blob_endpoint
  audit_storage_key      = module.storage_account.primary_access_key
  
  tags = local.common_tags
}

# SQL Database
module "sql_database" {
  source = "../../modules/azurerm_sql_database"
  
  sql_db_name = "${local.name_prefix}-sqldb"
  server_id   = module.sql_server.server_id
  max_size_gb = "10"
  
  tags = local.common_tags
}

# Public IP for AKS
module "public_ip" {
  source = "../../modules/azurerm_public_ip"
  
  pip_name = "${local.name_prefix}-aks-pip"
  rg_name = module.resource_group.resource_group_name
  location = local.location
  sku = "Standard"
  
  tags = local.common_tags
}

# AKS Cluster
module "aks_cluster" {
  source = "../../modules/azurerm_kubernetes_cluster"
  
  cluster_name = "${local.name_prefix}-aks"
  location     = local.location
  resource_group_name = module.resource_group.resource_group_name
  dns_prefix   = "${local.name_prefix}-aks"
  
  default_node_pool_name = "default"
  default_node_pool_count = 2
  default_node_pool_vm_size = "Standard_D4s_v3"
  vnet_subnet_id = module.virtual_network.subnet_ids["aks-subnet"]
  
  enable_auto_scaling = true
  min_count = 2
  max_count = 10
  max_pods = 50
  os_disk_size_gb = 50
  
  network_plugin = "azure"
  network_policy = "azure"
  service_cidr = "10.2.0.0/16"
  dns_service_ip = "10.2.0.10"
  docker_bridge_cidr = "172.18.0.1/16"
  
  rbac_enabled = true
  aad_rbac_enabled = true
  admin_group_object_ids = [data.azurerm_client_config.current.object_id]
  
  # Restrict API server access to specific IP ranges (add your office/home IP)
  api_server_authorized_ip_ranges = ["10.1.0.0/16", "10.2.0.0/16"]

  # Enable OMS agent by wiring a prod Log Analytics workspace
  log_analytics_workspace_id = azurerm_log_analytics_workspace.prod_law.id
  
  additional_node_pools = {
    "system" = {
      vm_size = "Standard_D4s_v3"
      node_count = 2
      os_type = "Linux"
      mode = "System"
    }
    "user" = {
      vm_size = "Standard_D4s_v3"
      node_count = 1
      enable_auto_scaling = true
      min_count = 1
      max_count = 5
      os_type = "Linux"
      mode = "User"
    }
  }
  
  tags = local.common_tags
}

# Log Analytics Workspace for AKS logging (prod)
resource "azurerm_log_analytics_workspace" "prod_law" {
  name                = "${local.name_prefix}-law"
  location            = local.location
  resource_group_name = module.resource_group.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = 30

  tags = local.common_tags
}

# Managed Identity for AKS
module "managed_identity" {
  source = "../../modules/azurerm_managed_identity"
  
  identity_name = "${local.name_prefix}-aks-identity"
  resource_group_name = module.resource_group.resource_group_name
  location = local.location
  
  tags = local.common_tags
}

# ACR
module "acr" {
  source = "../../modules/azurerm_container_registry"

  acr_name = lower(replace("${local.name_prefix}acr${random_string.stg_suffix.result}", "-", ""))
  rg_name  = module.resource_group.resource_group_name
  location = local.location
  sku      = "Standard"

  admin_enabled = false
  tags          = local.common_tags
}