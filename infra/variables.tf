variable "zone" {
  description = "Exoscale zone. ch-dk-2 is Zurich, ch-gva-2 is Geneva."
  type        = string
  default     = "ch-dk-2"
}

variable "name" {
  description = "Name prefix for every resource."
  type        = string
  default     = "safelife"
}

variable "admin_cidr" {
  description = "Your public address, in CIDR form. Gates SSH and direct database access."
  type        = string

  validation {
    # An empty or malformed value here silently produces "/32", which the Exoscale API
    # rejects with a message that points nowhere near the real cause.
    condition     = can(cidrnetmask(var.admin_cidr))
    error_message = "admin_cidr must be valid CIDR, e.g. 203.0.113.10/32 - run: echo \"$(curl -s https://ifconfig.me)/32\""
  }
}

variable "device_port" {
  description = "TCP port the TWIG devices connect to."
  type        = number
  default     = 9770
}

variable "device_source_cidrs" {
  description = "Source ranges allowed to reach the device port. Narrow this as soon as TWIG provide their ranges."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "instance_type" {
  description = "standard.small = 2 vCPU / 2 GiB, CHF 16.80/mo. standard.medium = 2 vCPU / 4 GiB, CHF 33.60."
  type        = string
  default     = "standard.small"
}

variable "disk_size" {
  description = "Boot disk in GiB. Docker images and logs are what actually fill this."
  type        = number
  default     = 20
}

variable "ssh_public_key_path" {
  description = "Public half of the key created in runbook step 1."
  type        = string
  default     = "~/.ssh/exoscale_safelife.pub"
}

variable "managed_database" {
  description = <<-EOT
    true  = Exoscale managed Postgres (hobbyist-2, CHF 41.84/mo) - backups and patching included.
    false = no database resource; run Postgres in a container on the instance instead.
            Saves the 41.84 but you own backups, and it dies with the instance.
  EOT
  type        = bool
  default     = true
}

variable "db_plan" {
  description = "hobbyist-2 is the cheapest managed plan Exoscale sells. startup-4 is the next step up (80 GiB)."
  type        = string
  default     = "hobbyist-2"
}

variable "pg_version" {
  type    = string
  default = "17"
}
