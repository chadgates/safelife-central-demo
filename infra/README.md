# Terraform — SafeLife Central infrastructure

Replaces the `exo` commands in [`../deploy/RUNBOOK.md`](../deploy/RUNBOOK.md) steps 1–5 with
something reproducible. The runbook stays useful as the explanation of *why* each piece exists;
this is the version you can destroy and rebuild identically.

Terraform creates the **infrastructure**. Deploying a new image is the
[`deploy` workflow](../.github/workflows/deploy.yml) — different lifecycle, different tool.

## What it creates

| Resource | Notes |
|---|---|
| `exoscale_ssh_key` | from `~/.ssh/exoscale_safelife.pub` |
| `exoscale_security_group` + 4 rules | SSH from your address only; 80, 443, and the device port |
| `exoscale_elastic_ip` | **managed**, TCP healthcheck on the device port — the address you give TWIG |
| `exoscale_compute_instance` | Ubuntu 24.04, cloud-init from `../deploy/cloud-init.yaml`, EIP attached |
| `exoscale_database` | Postgres, IP-filtered to you and the instance. Optional — see below |

## Run it

```zsh
export EXOSCALE_API_KEY='EXO...'      # IAM → Keys. Never put these in a .tf file.
export EXOSCALE_API_SECRET='...'

cd infra
cp terraform.tfvars.example terraform.tfvars
${EDITOR:-nano} terraform.tfvars       # admin_cidr is required

terraform init
terraform plan            # read it. "must be replaced" on the instance is a device outage.
terraform apply
```

Then write the database half of the env file and carry on from runbook step 6:

```zsh
terraform output -raw app_env > ../deploy/app.env
terraform output device_endpoint        # this is what TWIG gets
```

## The cheaper start

`hobbyist-2` at CHF 41.84 is the cheapest managed Postgres Exoscale sells — there is nothing
below it. To go cheaper you have to stop using a managed database:

```hcl
managed_database = false
instance_type    = "standard.medium"   # 4 GiB, so Postgres has somewhere to live
```

| | CHF/month | You own |
|---|---|---|
| `standard.small` + `hobbyist-2` | 58.64 | nothing below the container |
| `standard.medium` + Postgres container | 33.60 | backups, patching; it dies with the instance |
| `standard.small` + Postgres container | 16.80 | the same, on 2 GiB shared with the app |

With `managed_database = false` no database resource is created and `app_env` points at
`127.0.0.1`. You then add a `postgres:17` service to `deploy/docker-compose.yml` with a named
volume, and a nightly `pg_dump` to Object Storage (CHF 0.0198/GiB — pennies). Perfectly
reasonable for a prototype; add the managed service back before real devices depend on it.

## State holds secrets

`terraform.tfstate` contains the database password. It is gitignored. The moment a second
person or CI runs this, move it to Exoscale Object Storage — the S3 backend block is in
`versions.tf`, commented out.

## Things the plan will tell you, that are worth reading

- **Changing `instance_type` or `disk_size` restarts the instance.** That is a device outage.
- **`template_id` is in `ignore_changes`**, so a new Ubuntu image does not silently rebuild
  your host. Rebuild deliberately.
- **The Elastic IP is managed**, meaning Exoscale healthchecks the backend before routing. Until
  the container is up and the device port answers, traffic is not forwarded — that is correct
  behaviour, not a fault.
- **`termination_protection = false`** on the database, so `destroy` works. Set it to `true`
  once anything real is in there.

## Verified

The provider is not installed here, so `terraform validate` has not been run against this
configuration. What *has* been checked: every resource type, data source and attribute used
was cross-checked against the provider's published schema
(`exoscale/terraform-provider-exoscale` docs) — 8 types, 0 undocumented attributes.
Run `terraform validate` yourself before the first apply.
