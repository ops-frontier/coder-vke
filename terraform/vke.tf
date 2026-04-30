# VPC
resource "vultr_vpc" "main" {
  description    = "${var.vultr_label_prefix}-vke-vpc"
  region         = var.vultr_region
  v4_subnet      = "10.0.0.0"
  v4_subnet_mask = 24
}

# VKE Cluster
resource "vultr_kubernetes" "main" {
  region     = var.vultr_region
  label      = "${var.vultr_label_prefix}-vke-cluster"
  version    = "v1.35.2+1"
  ha_controlplanes = var.vke_ha_control_plane
  enable_firewall  = var.vke_enable_firewall

  node_pools {
    node_quantity = 2
    plan          = var.vke_node_plan
    label         = "${var.vultr_label_prefix}-nodepool"
    auto_scaler   = false
  }
}

# Save kubeconfig locally
resource "local_sensitive_file" "kubeconfig" {
  content         = base64decode(vultr_kubernetes.main.kube_config)
  filename        = "${path.module}/../kubeconfig"
  file_permission = "0600"
}
