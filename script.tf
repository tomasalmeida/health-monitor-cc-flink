provider "docker" {
  host = "unix:///var/run/docker.sock"
}

locals {
  kafka_bootstrap = confluent_kafka_cluster.cluster_kafka_demo.bootstrap_endpoint
  kafka_topic     = confluent_kafka_topic.topic_events.topic_name
  api_key         = confluent_api_key.api_key_sa_demo.id
  api_secret      = confluent_api_key.api_key_sa_demo.secret
  sr_endpoint     = data.confluent_schema_registry_cluster.sr_cluster.rest_endpoint
  sr_key          = confluent_api_key.api_key_sa_sr_demo.id
  sr_secret       = confluent_api_key.api_key_sa_sr_demo.secret
  config_data = {
    interval = 0.2
    duration = 0
    kafka = {
      "bootstrap.servers" = local.kafka_bootstrap
      "security.protocol" = "SASL_SSL"
      "sasl.mechanisms"   = "PLAIN"
      "sasl.username"     = local.api_key
      "sasl.password"     = local.api_secret
      acks                 = "all"
      "linger.ms"         = 5
      topic                = local.kafka_topic
      "schema.registry.url" = local.sr_endpoint
      "basic.auth.credentials.source" = "USER_INFO"
      "basic.auth.user.info" = "${local.sr_key}:${local.sr_secret}"
    }
  }
}

resource "local_file" "health_simulator_config" {
  filename = "${path.module}/config.json"
  content  = jsonencode(local.config_data)
  depends_on = [
    confluent_api_key.api_key_sa_demo,
    confluent_api_key.api_key_sa_sr_demo,
    confluent_kafka_topic.topic_events,
    confluent_schema.events_value
  ]
}

resource "docker_image" "health_simulator" {
  name = "health-simulator:latest"
  keep_locally = true
  build {
    context    = "${path.module}"
    dockerfile = "${path.module}/health-simulator/Dockerfile"
  }
  triggers = {
    script_sha = filesha1("${path.module}/health-simulator/health_simulator.py")
    config_sha = sha1(jsonencode(local.config_data))
  }
  depends_on = [local_file.health_simulator_config]
}

output "how-to-run" {

  value = <<-EOT

----------------------------
   Health generator how to run
------------------------------
  $ docker run health-simulator:latest
  EOT

  sensitive = false
}