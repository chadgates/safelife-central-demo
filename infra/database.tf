resource "exoscale_database" "pg" {
  count = var.managed_database ? 1 : 0

  zone = var.zone
  name = "${var.name}-db"
  type = "pg"
  plan = var.db_plan

  maintenance_dow  = "sunday"
  maintenance_time = "03:00:00"

  # Refuses to destroy while true. Flip it deliberately before a teardown.
  termination_protection = false

  pg = {
    version         = var.pg_version
    backup_schedule = "02:00"

    # Only these two can reach the database. Everything else is refused at the edge, which
    # matters because the service sits on a public hostname with no network in front of it.
    ip_filter = [
      var.admin_cidr,
      "${exoscale_compute_instance.app.public_ip_address}/32",
    ]
  }
}

# The resource's own `uri` attribute has the credentials stripped out. This data source is
# the supported way to read them back as discrete fields.
data "exoscale_database_uri" "pg" {
  count = var.managed_database ? 1 : 0

  name = exoscale_database.pg[0].name
  type = "pg"
  zone = var.zone

  depends_on = [exoscale_database.pg]
}
