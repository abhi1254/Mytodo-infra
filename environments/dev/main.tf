terraform {
  backend "azurerm" {
    resource_group_name  = "backuprg"
    storage_account_name = "backupstorge"
    container_name       = "backupcontainer1254"
    key                  = "dev.terraform.tfstate"
  }
}

# Data sources
data "azurerm_client_config" "current" {}

# Random string for unique naming
resource "random_string" "suffix" {
  length  = 4
  special = false
  upper   = false
}

# Local values
locals {
  common_tags = {
    "ManagedBy"   = "Terraform"
    "Owner"       = "TodoAppTeam"
    "Environment" = "dev"
    "Project"     = "TodoApp"
  }
  
  # Naming convention
  name_prefix = "todo-dev-${random_string.suffix.result}"
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
  address_space      = ["10.0.0.0/16"]
  
  subnets = {
    "aks-subnet" = {
      address_prefixes = ["10.0.1.0/24"]
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
          source_address_prefix      = "10.0.0.0/16"
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
          source_address_prefix      = "10.0.0.0/16"
          destination_address_prefix = "*"
        }
      ]
    }
    "sql-subnet" = {
      address_prefixes = ["10.0.2.0/24"]
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
  sku_name            = "standard"
  
  purge_protection_enabled = true
  soft_delete_retention_days = 7
  
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
      value = "TodoAppDev2024!"
      content_type = "text/plain"
      expiration_date = "2025-12-31T23:59:59Z"
    }
  }
  
  tags = local.common_tags
}

# Storage Account
module "storage_account" {
  source = "../../modules/azurerm_storage_account"
  
  storage_account_name   = "tododevstg${random_string.suffix.result}"
  resource_group_name    = module.resource_group.resource_group_name
  location              = local.location
  account_tier          = "Standard"
  account_replication_type = "LRS"
  min_tls_version       = "TLS1_2"
  allow_nested_items_to_be_public = false
  
  tags = local.common_tags
}

# SQL Server
module "sql_server" {
  source = "../../modules/azurerm_sql_server"
  
  sql_server_name = "${local.name_prefix}-sql"
  rg_name = module.resource_group.resource_group_name
  location        = local.location
  admin_username  = "todoappadmin"
  admin_password  = "TodoAppDev2024!"
  
  audit_storage_endpoint = module.storage_account.primary_blob_endpoint
  audit_storage_key      = module.storage_account.primary_access_key
  
  tags = local.common_tags
}

# SQL Database
module "sql_database" {
  source = "../../modules/azurerm_sql_database"
  
  sql_db_name = "${local.name_prefix}-sqldb"
  server_id   = module.sql_server.server_id
  max_size_gb = "2"
  
  tags = local.common_tags
}

# Public IP module removed - using existing public IPs

# AKS Cluster
module "aks_cluster" {
  source = "../../modules/azurerm_kubernetes_cluster"
  
  cluster_name = "${local.name_prefix}-aks"
  location     = local.location
  resource_group_name = module.resource_group.resource_group_name
  dns_prefix   = "${local.name_prefix}-aks"
  
  default_node_pool_name = "default"
  default_node_pool_count = 1
  default_node_pool_vm_size = "Standard_D2s_v3"
  vnet_subnet_id = module.virtual_network.subnet_ids["aks-subnet"]
  
  enable_auto_scaling = true
  min_count = 1
  max_count = 3
  max_pods = 30
  os_disk_size_gb = 30
  
  network_plugin = "azure"
  network_policy = "azure"
  service_cidr = "10.1.0.0/16"
  dns_service_ip = "10.1.0.10"
  docker_bridge_cidr = "172.17.0.1/16"
  
  rbac_enabled = true
  aad_rbac_enabled = false
  
  # Restrict API server access to specific IP ranges (add your office/home IP)
  api_server_authorized_ip_ranges = ["10.0.0.0/16", "10.1.0.0/16"]

  # Enable OMS agent by wiring a dev Log Analytics workspace
  log_analytics_workspace_id = azurerm_log_analytics_workspace.dev_law.id
  
  additional_node_pools = {
    "system" = {
      vm_size = "Standard_D2s_v3"
      node_count = 1
      os_type = "Linux"
      mode = "System"
    }
  }
  
  tags = local.common_tags
}

# Log Analytics Workspace for AKS logging (dev)
resource "azurerm_log_analytics_workspace" "dev_law" {
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