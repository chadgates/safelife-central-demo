output "device_endpoint" {
  description = "Give THIS to TWIG. It outlives the instance."
  value       = "${exoscale_elastic_ip.devices.ip_address}:${var.device_port}"
}

output "elastic_ip" {
  description = "The reserved address itself - point your DNS A record here, not at the instance."
  value       = exoscale_elastic_ip.devices.ip_address
}

output "instance_ip" {
  description = "The instance's own address. For SSH only - it dies with the instance."
  value       = exoscale_compute_instance.app.public_ip_address
}

output "ssh" {
  value = "ssh -i ${replace(var.ssh_public_key_path, ".pub", "")} ubuntu@${exoscale_compute_instance.app.public_ip_address}"
}

# The database half of /etc/safelife/app.env, ready to write. Sensitive, so a bare apply does
# not print it:  terraform output -raw app_env
output "app_env" {
  sensitive   = true
  description = "terraform output -raw app_env > ../deploy/app.env   (then add the Twilio and SendGrid blocks)"

  value = var.managed_database ? join("\n", [
    "PGHOST=${data.exoscale_database_uri.pg[0].host}",
    "PGPORT=${data.exoscale_database_uri.pg[0].port}",
    "PGDATABASE=${data.exoscale_database_uri.pg[0].db_name}",
    "PGUSER=${data.exoscale_database_uri.pg[0].username}",
    "PGPASSWORD=${data.exoscale_database_uri.pg[0].password}",
    "PGSSLMODE=Require",
    "PGTRUSTSERVERCERT=true",
    "PGMAXPOOL=8",
    ]) : join("\n", [
    "# Managed database disabled: Postgres runs as a container beside the app.",
    "PGHOST=127.0.0.1",
    "PGPORT=5432",
    "PGDATABASE=safelife",
    "PGUSER=safelife",
    "PGPASSWORD=set-this-in-both-app.env-and-the-compose-file",
    "PGSSLMODE=Disable",
    "PGTRUSTSERVERCERT=false",
    "PGMAXPOOL=8",
  ])
}

output "monthly_chf" {
  description = "List prices excluding VAT. A sanity check, not an invoice."
  value = format(
    "%s + elastic ip 10.00 + %s = about CHF %.2f/month",
    var.instance_type,
    var.managed_database ? var.db_plan : "postgres in a container",
    lookup({ "standard.small" = 16.80, "standard.medium" = 33.60, "standard.large" = 67.20 }, var.instance_type, 0)
    + 10.00
    + (var.managed_database ? lookup({ "hobbyist-2" = 41.84, "startup-4" = 98.49 }, var.db_plan, 0) : 0)
  )
}

# The database connection in the form the .NET service actually wants. Npgsql cannot parse a
# postgres:// URI, so we hand over a composed connection string rather than a URL.
#   tofu output -raw connection_string_dotnet
output "connection_string_dotnet" {
  sensitive   = true
  description = "One ConnectionStrings__<name> line, ready to paste into app.env."

  value = var.managed_database ? join("", [
    "ConnectionStrings__${var.connection_string_name}=",
    "Host=${data.exoscale_database_uri.pg[0].host};",
    "Port=${data.exoscale_database_uri.pg[0].port};",
    "Database=${data.exoscale_database_uri.pg[0].db_name};",
    "Username=${data.exoscale_database_uri.pg[0].username};",
    "Password=${data.exoscale_database_uri.pg[0].password};",
    # Managed Postgres refuses plaintext and presents a certificate from its own CA, so
    # hostname verification has to be off. The pool cap keeps us under the ~20 connection
    # ceiling of the entry-tier plan.
    "SSL Mode=Require;Trust Server Certificate=true;Maximum Pool Size=8",
    ]) : join("", [
    "ConnectionStrings__${var.connection_string_name}=",
    "Host=127.0.0.1;Port=5432;Database=safelife;Username=safelife;Password=CHANGE_ME;",
    "SSL Mode=Disable;Maximum Pool Size=8",
  ])
}
