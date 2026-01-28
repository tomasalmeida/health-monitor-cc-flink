terraform {
  required_providers {
    confluent = {
      source  = "confluentinc/confluent"
      version = "2.58.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
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

data "confluent_schema_registry_cluster" "sr_cluster" {
  environment {
    id = confluent_environment.env_demo.id
  }

  depends_on = [
    confluent_kafka_cluster.cluster_kafka_demo
  ]
}

resource "confluent_service_account" "sa_demo" {
  display_name = "${var.use_prefix}-demo-sa"
  description  = "Service account for device event generator"
}

resource "confluent_role_binding" "rbac_sa_demo" {
  depends_on = [ confluent_kafka_cluster.cluster_kafka_demo, confluent_service_account.sa_demo ]

  principal   = "User:${confluent_service_account.sa_demo.id}"
  role_name   = "EnvironmentAdmin"
  crn_pattern = confluent_environment.env_demo.resource_name
}

resource "confluent_role_binding" "rbac_sa_demo_flink" {  
  depends_on = [ confluent_kafka_cluster.cluster_kafka_demo, confluent_service_account.sa_demo ]

  principal   = "User:${confluent_service_account.sa_demo.id}"
  role_name   = "FlinkAdmin"
  crn_pattern = confluent_environment.env_demo.resource_name
}

resource "confluent_role_binding" "rbac_account_flink" {
  depends_on = [ confluent_kafka_cluster.cluster_kafka_demo, confluent_service_account.sa_demo ]

  principal   = "User:${var.confluent_cloud_account}"
  role_name   = "FlinkAdmin"
  crn_pattern = confluent_environment.env_demo.resource_name
}

resource "confluent_role_binding" "rbac_sa_demo_env" {
  depends_on = [ confluent_kafka_cluster.cluster_kafka_demo, confluent_service_account.sa_demo ]

  principal   = "User:${confluent_service_account.sa_demo.id}"
  role_name   = "EnvironmentAdmin"
  crn_pattern = confluent_environment.env_demo.resource_name
}

resource "confluent_role_binding" "rbac_cloud_user_sr" {
  depends_on = [ confluent_kafka_cluster.cluster_kafka_demo, confluent_service_account.sa_demo ]

  principal   = "User:${var.confluent_cloud_account}"
  role_name  = "ResourceOwner"
  crn_pattern = "${data.confluent_schema_registry_cluster.sr_cluster.resource_name}/subject=*"
}

resource "confluent_role_binding" "rbac_sa_demo_sr" {
  depends_on = [ confluent_kafka_cluster.cluster_kafka_demo, confluent_service_account.sa_demo ]

  principal   = "User:${confluent_service_account.sa_demo.id}"
  role_name  = "ResourceOwner"
  crn_pattern = "${data.confluent_schema_registry_cluster.sr_cluster.resource_name}/subject=*"
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

resource "confluent_api_key" "api_key_sa_sr_demo" {
  display_name = "${var.use_prefix}-schema-registry-api-key"
  description  = "Schema Registry API Key that is owned by '${confluent_service_account.sa_demo.display_name}' service account"
  
  owner {
    id          = confluent_service_account.sa_demo.id
    api_version = confluent_service_account.sa_demo.api_version
    kind        = confluent_service_account.sa_demo.kind
  }
  managed_resource {
    id          = data.confluent_schema_registry_cluster.sr_cluster.id
    api_version = data.confluent_schema_registry_cluster.sr_cluster.api_version
    kind        = data.confluent_schema_registry_cluster.sr_cluster.kind
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

resource "confluent_flink_compute_pool" "flink_compute_pool" {
  depends_on = [ confluent_kafka_cluster.cluster_kafka_demo ]

  display_name = "${var.use_prefix}-flink-compute-pool"
  cloud        = confluent_kafka_cluster.cluster_kafka_demo.cloud
  region       = confluent_kafka_cluster.cluster_kafka_demo.region
  max_cfu      = 20
  environment {
    id = confluent_environment.env_demo.id
  }  
}
