data "exoscale_template" "ubuntu" {
  zone = var.zone
  name = "Linux Ubuntu 24.04 LTS 64-bit"
}

resource "exoscale_ssh_key" "admin" {
  name       = "${var.name}-key"
  public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
}

resource "exoscale_compute_instance" "app" {
  zone = var.zone
  name = "${var.name}-app"

  template_id = data.exoscale_template.ubuntu.id
  type        = var.instance_type
  disk_size   = var.disk_size

  ssh_keys           = [exoscale_ssh_key.admin.name]
  security_group_ids = [exoscale_security_group.app.id]
  elastic_ip_ids     = [exoscale_elastic_ip.devices.id]

  # Docker, firewall, TCP sysctls, and the safelife systemd unit.
  user_data = file("${path.module}/../deploy/cloud-init.yaml")

  # Changing the boot disk or instance type restarts the machine. Terraform will say so in
  # the plan; read it before approving, because it is a device outage.
  lifecycle {
    ignore_changes = [template_id] # a new Ubuntu build should not silently rebuild the host
  }
}
