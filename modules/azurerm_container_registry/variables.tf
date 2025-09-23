variable "acr_name" {
  description = "Name of the Azure Container Registry (must be globally unique, lowercased, 5-50 chars)"
  type        = string
}

variable "rg_name" {
  description = "Resource group name"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
}

variable "sku" {
  description = "ACR SKU"
  type        = string
  default     = "Basic"
}

variable "admin_enabled" {
  description = "Whether admin user is enabled"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags map"
  type        = map(string)
  default     = {}
}


