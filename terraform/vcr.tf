# Vultr Container Registry - ワークスペースイメージを格納する
resource "vultr_container_registry" "workspace" {
  name   = "${replace(var.vultr_label_prefix, "-", "")}workspace"
  region = var.vultr_region
  plan   = "start_up"
  public = false
}
