terraform {
  required_version = ">= 1.6"

  required_providers {
    exoscale = {
      source  = "exoscale/exoscale"
      version = "~> 0.62"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # State contains the database password. Local state is fine for one operator; the moment
  # a second person or CI runs this, move it to Exoscale Object Storage (S3-compatible):
  #
  # backend "s3" {
  #   bucket                      = "safelife-tfstate"
  #   key                         = "prod/terraform.tfstate"
  #   endpoints                   = { s3 = "https://sos-ch-dk-2.exo.io" }
  #   region                      = "ch-dk-2"
  #   skip_credentials_validation = true
  #   skip_region_validation      = true
  #   skip_requesting_account_id  = true
  #   skip_s3_checksum            = true
  #   use_path_style              = true
  # }
}

# Credentials come from EXOSCALE_API_KEY / EXOSCALE_API_SECRET so they never land in a file.
provider "exoscale" {}
