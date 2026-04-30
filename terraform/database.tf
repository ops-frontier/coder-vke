# PostgreSQL Managed Database for Coder
resource "vultr_database" "coder" {
  database_engine         = "pg"
  database_engine_version = "16"
  region                  = var.vultr_region
  plan                    = "vultr-dbaas-startup-cc-1-55-2"
  label                   = "${var.vultr_label_prefix}-coder-pg"
  cluster_time_zone       = "Asia/Tokyo"
  trusted_ips             = []

  lifecycle {
    ignore_changes = [trusted_ips]
  }
}
