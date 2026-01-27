# Schema Registry subject for the 'events' topic
# Ensures Flink sees proper columns like patient_id

resource "confluent_schema" "events_value" {
  subject_name = "events-value"
  format       = "AVRO"
  schema       = <<EOF
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

  schema_registry_cluster {
    id = data.confluent_schema_registry_cluster.sr_cluster.id
  }
  rest_endpoint = data.confluent_schema_registry_cluster.sr_cluster.rest_endpoint
  credentials {
    key    = confluent_api_key.api_key_sa_sr_demo.id
    secret = confluent_api_key.api_key_sa_sr_demo.secret
  }

  depends_on = [
    confluent_kafka_topic.topic_events
  ]
}
