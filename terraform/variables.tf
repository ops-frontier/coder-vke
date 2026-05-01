variable "vultr_api_key" {
  description = "Vultr API key"
  type        = string
  sensitive   = true
}

variable "do_pat" {
  description = "DigitalOcean Personal Access Token"
  type        = string
  sensitive   = true
}

variable "vultr_label_prefix" {
  description = "Prefix for Vultr resource labels"
  type        = string
  default     = "coder"
}

variable "vultr_region" {
  description = "Vultr region"
  type        = string
  default     = "nrt"
}

variable "vke_node_plan" {
  description = "VKE node plan"
  type        = string
  default     = "vc2-4c-8gb"
}

variable "vke_ha_control_plane" {
  description = "Enable HA control plane for VKE"
  type        = bool
  default     = true
}

variable "vke_enable_firewall" {
  description = "Enable firewall for VKE"
  type        = bool
  default     = true
}

variable "domain" {
  description = "Domain delegated to DigitalOcean DNS"
  type        = string
}

variable "gh_organization" {
  description = "GitHub organization ID"
  type        = string
  default     = "ops-frontier"
}

variable "gh_client_id" {
  description = "GitHub OAuth Client ID"
  type        = string
  sensitive   = true
}

variable "gh_client_secret" {
  description = "GitHub OAuth Client Secret"
  type        = string
  sensitive   = true
}

variable "le_environment" {
  description = "Let's Encrypt environment: production or staging"
  type        = string
  default     = "production"
  validation {
    condition     = contains(["production", "staging"], var.le_environment)
    error_message = "le_environment must be 'production' or 'staging'."
  }
}

variable "coder_postgresql_size" {
  description = "Size in GB for Coder PostgreSQL managed DB"
  type        = number
  default     = 10
}

variable "coder_workspace_default_size" {
  description = "Default workspace size in GB"
  type        = number
  default     = 20
}
