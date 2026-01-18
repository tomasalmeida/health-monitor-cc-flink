# Health monitor with CC Flink

**Overview**

**Prerequisites**

**Configure Variables**
- Create a `terraform.tfvars` with your credentials and a resource prefix:

```bash
cat > "$PWD/terraform.tfvars" <<EOF
confluent_cloud_api_key    = "<Your Confluent Cloud API Key>"
confluent_cloud_api_secret = "<Your Confluent Cloud API Secret>"
use_prefix                 = "<your-prefix>"
EOF
```

Variables defined in this project:
- `confluent_cloud_api_key`: Cloud API ID.
- `confluent_cloud_api_secret`: Cloud API Secret (sensitive).
- `use_prefix`: Prefix added to names of all created resources.

Note: Do not commit `terraform.tfvars` or `.tfstate` files to source control.

**Deploy**
```bash
terraform init
terraform plan
terraform apply
```

Deployment creates an environment and all dependent resources. The Flink statements run after the compute pool is ready.

**Clean Up**
```bash
terraform destroy
```
If destroy fails due to statement dependencies, try one of the following:
- Temporarily comment out all resources in `flink_statements.tf` and rerun `terraform destroy`.
- Or destroy the statements first, then the compute pool and remaining resources.

**Troubleshooting**
- Auth/permission errors: Ensure the Cloud API Key/Secret have sufficient org/environment privileges.
- Provider version: The configuration pins `confluentinc/confluent` to `2.34.0`. Run `terraform init -upgrade` if you change it.
- Region mismatch: The Flink region is derived from the Kafka cluster’s cloud/region; keep them aligned.

## Disclaimer

The code and/or instructions here available are **NOT** intended for production usage.
It's only meant to serve as an example or reference and does not replace the need to follow actual and official documentation of referenced products.
