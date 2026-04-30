output "kubeconfig_path" {
  description = "Path to the kubeconfig file"
  value       = local_sensitive_file.kubeconfig.filename
}

output "cluster_id" {
  description = "VKE cluster ID"
  value       = vultr_kubernetes.main.id
}

output "database_host" {
  description = "PostgreSQL host"
  value       = vultr_database.coder.host
  sensitive   = true
}

output "database_port" {
  description = "PostgreSQL port"
  value       = vultr_database.coder.port
}

output "database_user" {
  description = "PostgreSQL user"
  value       = vultr_database.coder.user
  sensitive   = true
}

output "database_password" {
  description = "PostgreSQL password"
  value       = vultr_database.coder.password
  sensitive   = true
}

output "database_name" {
  description = "PostgreSQL database name"
  value       = vultr_database.coder.dbname
}

output "vcr_id" {
  description = "Vultr Container Registry ID"
  value       = vultr_container_registry.workspace.id
}

output "vcr_image" {
  description = "Workspace container image URL (before :tag)"
  value       = "${var.vultr_region}.vultrcr.com/${vultr_container_registry.workspace.name}/workspace"
}
