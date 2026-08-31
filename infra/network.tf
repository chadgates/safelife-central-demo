resource "exoscale_security_group" "app" {
  name        = "${var.name}-sg"
  description = "SafeLife Central: web, device listener, admin SSH"
}

# SSH: your address only. Never 0.0.0.0/0.
resource "exoscale_security_group_rule" "ssh" {
  security_group_id = exoscale_security_group.app.id
  description       = "admin ssh"
  type              = "INGRESS"
  protocol          = "TCP"
  cidr              = var.admin_cidr
  start_port        = 22
  end_port          = 22
}

# 80 is not optional even once TLS is on: Caddy needs it for the ACME HTTP-01 challenge
# and for the redirect to HTTPS.
resource "exoscale_security_group_rule" "http" {
  security_group_id = exoscale_security_group.app.id
  description       = "http + ACME challenge"
  type              = "INGRESS"
  protocol          = "TCP"
  cidr              = "0.0.0.0/0"
  start_port        = 80
  end_port          = 80
}

resource "exoscale_security_group_rule" "https" {
  security_group_id = exoscale_security_group.app.id
  description       = "https, and the Twilio inbound webhook"
  type              = "INGRESS"
  protocol          = "TCP"
  cidr              = "0.0.0.0/0"
  start_port        = 443
  end_port          = 443
}

# The device listener. One rule per source range so they can be tightened individually.
resource "exoscale_security_group_rule" "devices" {
  for_each = toset(var.device_source_cidrs)

  security_group_id = exoscale_security_group.app.id
  description       = "TWIG device listener"
  type              = "INGRESS"
  protocol          = "TCP"
  cidr              = each.value
  start_port        = var.device_port
  end_port          = var.device_port
}

# The address the device fleet is given. It belongs to the organisation, not the instance:
# it survives the instance being destroyed and recreated, which is the entire reason for
# using one. Never hand out exoscale_compute_instance.app.public_ip_address.
#
# "Managed" (it has a healthcheck) means Exoscale routes to healthy backends and nothing has
# to be configured inside the VM. Note the consequence: until the container is up and the
# port answers, the healthcheck fails and traffic is not routed.
resource "exoscale_elastic_ip" "devices" {
  zone        = var.zone
  description = "SafeLife device endpoint - give this to TWIG"

  healthcheck {
    mode         = "tcp"
    port         = var.device_port
    interval     = 10
    timeout      = 5
    strikes_ok   = 2
    strikes_fail = 3
  }
}
