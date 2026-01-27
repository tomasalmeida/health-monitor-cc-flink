# Health monitor with Confluent Cloud Flink

## Overview
This demo provisions a Confluent Cloud environment, Kafka cluster, Schema Registry, and a Flink compute pool. It then deploys Flink SQL statements that process incoming health telemetry events and write results to downstream topics for analytics or alerting.

The health simulator is a Python container that generates realistic, time‑series health events (heart rate, SpO2, blood pressure, temperature) and publishes them to Kafka using Avro with Schema Registry.

## What this demo does
1. Creates Confluent Cloud resources (environment, Kafka cluster, Schema Registry, service accounts, API keys).
2. Creates Kafka topics for raw events and derived outputs.
3. Deploys Flink SQL statements to enrich/transform data.
4. Builds and runs a local Docker container that produces synthetic health events into Kafka.

## Prerequisites
- Confluent Cloud account with permissions to create environments, clusters, Flink compute pools, and Schema Registry.
- Terraform 1.5+ installed.
- Docker installed and running.

**Configure Variables**
- Create a `terraform.tfvars` with your credentials and a resource prefix:

```bash
cat > "$PWD/terraform.tfvars" <<EOF
confluent_cloud_api_key    = "<Your Confluent Cloud API Key>"
confluent_cloud_api_secret = "<Your Confluent Cloud API Secret>"
use_prefix                 = "<your-prefix>"
email                      = "<your-email>"
db_password                = "YourPassword123!"
EOF
```

Variables defined in this project:
- `confluent_cloud_api_key`: Cloud API ID.
- `confluent_cloud_api_secret`: Cloud API Secret (sensitive).
- `use_prefix`: Prefix added to names of all created resources.
- `email`: Used for notifications or ownership metadata.
- `db_password`: Password used for the example database.

Note: Do not commit `terraform.tfvars` or `.tfstate` files to source control.

**Deploy**
```bash
terraform init
terraform plan
terraform apply
```

Deployment creates an environment and all dependent resources. The Flink statements run after the compute pool is ready.

## Run the health simulator
The simulator publishes Avro events to the Kafka topic created by Terraform.

```bash
docker run -d --name health-simulator \
	-v "$PWD/config.json:/app/config.json:ro" \
	health-simulator:latest
```

To view logs:
```bash
docker logs -f health-simulator
```

To stop the simulator:
```bash
docker stop health-simulator && docker rm health-simulator
```

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
- No events seen: Verify the simulator container is running and check its logs for Schema Registry or auth errors.

## Disclaimer

The code and/or instructions here available are **NOT** intended for production usage.
It's only meant to serve as an example or reference and does not replace the need to follow actual and official documentation of referenced products.
