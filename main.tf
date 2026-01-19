terraform {
  required_providers {
    confluent = {
      source  = "confluentinc/confluent"
      version = "2.58.0"
    }
  }
}
provider "confluent" {
  cloud_api_key    = var.confluent_cloud_api_key
  cloud_api_secret = var.confluent_cloud_api_secret
}

data "confluent_organization" "main" {}

data "confluent_flink_region" "main" {
  cloud = confluent_kafka_cluster.cluster_kafka_demo.cloud
  region = confluent_kafka_cluster.cluster_kafka_demo.region
}

resource "confluent_environment" "env_demo" {
  display_name = "${var.use_prefix}-health-monitor-env"
}

resource "confluent_kafka_cluster" "cluster_kafka_demo" {
  standard {
  }
  environment {
    id = confluent_environment.env_demo.id
  }
  region       = "us-east-1"
  display_name = "${var.use_prefix}-health-monitor-kafka-cluster"
  cloud        = "AWS"
  availability = "SINGLE_ZONE"
}

resource "confluent_service_account" "sa_demo" {
  display_name = "${var.use_prefix}-demo-sa"
  description  = "Service account for Kafka Connect Datagen device heartbeat connector"
}

resource "confluent_role_binding" "rbac_sa_demo" {
  depends_on = [ confluent_kafka_cluster.cluster_kafka_demo, confluent_service_account.sa_demo ]

  principal   = "User:${confluent_service_account.sa_demo.id}"
  role_name   = "CloudClusterAdmin"
  crn_pattern = confluent_kafka_cluster.cluster_kafka_demo.rbac_crn
}

resource "confluent_role_binding" "rbac_sa_demo_flink" {
  depends_on = [ confluent_kafka_cluster.cluster_kafka_demo, confluent_service_account.sa_demo ]

  principal   = "User:${confluent_service_account.sa_demo.id}"
  role_name   = "FlinkAdmin"
  crn_pattern = confluent_environment.env_demo.resource_name
}

resource "confluent_role_binding" "rbac_sa_demo_env" {
  depends_on = [ confluent_kafka_cluster.cluster_kafka_demo, confluent_service_account.sa_demo ]

  principal   = "User:${confluent_service_account.sa_demo.id}"
  role_name   = "EnvironmentAdmin"
  crn_pattern = confluent_environment.env_demo.resource_name
}

resource "confluent_api_key" "api_key_sa_demo" {
  display_name = "${var.use_prefix}-datagen-source-api-key"
  description  = "Kafka API Key that is owned by '${confluent_service_account.sa_demo.display_name}' service account"
  owner {
    id          = confluent_service_account.sa_demo.id
    api_version = confluent_service_account.sa_demo.api_version
    kind        = confluent_service_account.sa_demo.kind
  }

  managed_resource {
    id          = confluent_kafka_cluster.cluster_kafka_demo.id
    api_version = confluent_kafka_cluster.cluster_kafka_demo.api_version
    kind        = confluent_kafka_cluster.cluster_kafka_demo.kind

    environment {
      id = confluent_environment.env_demo.id
    }
  }
}

resource "confluent_api_key" "api_key_sa_demo_flink" {
  display_name = "${var.use_prefix}-datagen-source-api-key-flink"
  description  = "Kafka API Key that is owned by '${confluent_service_account.sa_demo.display_name}' service account for Flink"
  
  owner {
    id          = confluent_service_account.sa_demo.id
    api_version = confluent_service_account.sa_demo.api_version
    kind        = confluent_service_account.sa_demo.kind
  }
  managed_resource {
    id          = data.confluent_flink_region.main.id
    api_version = data.confluent_flink_region.main.api_version
    kind        = data.confluent_flink_region.main.kind
    environment {
      id = confluent_environment.env_demo.id
    }
  }
}

resource "confluent_kafka_topic" "topic_events" {
  depends_on = [ confluent_role_binding.rbac_sa_demo ]
  
  kafka_cluster {
    id = confluent_kafka_cluster.cluster_kafka_demo.id
  }
  
  topic_name       = "events"
  partitions_count = 3

  rest_endpoint = confluent_kafka_cluster.cluster_kafka_demo.rest_endpoint
  credentials {
    key    = confluent_api_key.api_key_sa_demo.id
    secret = confluent_api_key.api_key_sa_demo.secret
  }
}

resource "confluent_connector" "connector_datagen" {
  depends_on = [ confluent_kafka_topic.topic_events, confluent_role_binding.rbac_sa_demo ]
  config_nonsensitive = {
    "connector.class" = "DatagenSource"
    "name" = "${var.use_prefix}-health-signals-datagen-source"
    "kafka.auth.mode" = "SERVICE_ACCOUNT"
    "kafka.service.account.id" = confluent_service_account.sa_demo.id
    "kafka.topic" = "events"
    "schema.context.name" = "default"
    "output.data.format" = "AVRO"
    "schema.string" = <<EOF
{
  "namespace": "health_events",
  "name": "health_event",
  "type": "record",
  "fields": [
    {
      "name": "event_id",
      "type": {
        "type": "string",
        "arg.properties": {
          "length": 12
        }
      }
    },
    {
      "name": "patient_id",
      "type": {
        "type": "int",
        "arg.properties": { 
          "options": [1,2,3,4,5,6,7,8,9,10]
        }
      }
    },
    {
      "name": "device_metadata",
      "type": {
        "type": "record",
        "name": "device_metadata",
        "fields": [
          {
            "name": "device_type",
            "type": {
              "type": "string",
              "arg.properties": {
                "options": ["wearable_v4", "wearable_v3", "wearable_v2"]
              }
            }
          },
          {
            "name": "battery_level",
            "type": {
              "type": "int",
              "arg.properties": { 
                "options": [5,10,15,20,25,30,35,40,45,50,55,60,65,70,75,80,85,90,95,100]
              }
            }
          },
          {
            "name": "sensor_status",
            "type": {
              "type": "string",
              "arg.properties": {
                "options": ["stable", "noisy", "offline"]
              }
            }
          }
        ]
      }
    },
    {
      "name": "vitals",
      "type": {
        "type": "record",
        "name": "vitals",
        "fields": [
          {
            "name": "heart_rate",
            "type": {
              "type": "int",
              "arg.properties": { 
                "options": [55,60,65,70,75,80,85,90,95,100,105,110,115,120,125,130,135,140,145,150]
              }
            }
          },
          {
            "name": "blood_oxygen_spO2",
            "type": {
              "type": "int",
              "arg.properties": {
                "options": [82,84,86,88,90,92,94,96,98,100]
              }
            }
          },
          {
            "name": "blood_pressure",
            "type": {
              "type": "record",
              "name": "blood_pressure",
              "fields": [
                {
                  "name": "systolic",
                  "type": {
                    "type": "int",
                    "arg.properties": { 
                      "options": [90,95,100,105,110,115,120,125,130,135,140,145,150,155,160,165,170,175,180]
                    }
                  }
                },
                {
                  "name": "diastolic",
                  "type": {
                    "type": "int",
                    "arg.properties": { 
                      "options": [60,65,70,75,80,85,90,95,100,105,110,115,120]
                    }
                  }
                }
              ]
            }
          },
          {
            "name": "body_temperature_c",
            "type": {
              "type": "float",
              "arg.properties": { 
                "options": [35.0,35.5,36.0,36.5,37.0,37.5,38.0,38.5,39.0,39.5,40.0]
              }
            }
          }
        ]
      }
    }
  ]
}
EOF
    "max.interval" = "10"
    "tasks.max" = "10"
    "value.converter.decimal.format" = "BASE64"
    "value.converter.replace.null.with.default" = "true"
    "value.converter.reference.subject.name.strategy" = "DefaultReferenceSubjectNameStrategy"
    "value.converter.schemas.enable" = "true"
    "errors.tolerance" = "none"
    "value.converter.value.subject.name.strategy" = "TopicNameStrategy"
    "key.converter.key.subject.name.strategy" = "TopicNameStrategy"
    "value.converter.ignore.default.for.nullables" = "false"
    "auto.restart.on.user.error" = "true"
  }

  environment {
    id = confluent_environment.env_demo.id
  }

  kafka_cluster {
    id = confluent_kafka_cluster.cluster_kafka_demo.id
  }
}

resource "confluent_flink_compute_pool" "flink_compute_pool" {
  depends_on = [ confluent_kafka_cluster.cluster_kafka_demo, confluent_connector.connector_datagen ]

  display_name = "${var.use_prefix}-flink-compute-pool"
  cloud        = confluent_kafka_cluster.cluster_kafka_demo.cloud
  region       = confluent_kafka_cluster.cluster_kafka_demo.region
  max_cfu      = 20
  environment {
    id = confluent_environment.env_demo.id
  }  
}
