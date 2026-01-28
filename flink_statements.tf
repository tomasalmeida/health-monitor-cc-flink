# --------------------------------------------------------
# Step 1: Create a connection to read patient data from the source database
# --------------------------------------------------------

resource "confluent_flink_statement" "patientdb_connection" {
  depends_on = [
    confluent_flink_compute_pool.flink_compute_pool,
    null_resource.create_tables
  ]   
  organization {
    id = data.confluent_organization.main.id
  } 
  environment {
    id = confluent_environment.env_demo.id 
  } 
  compute_pool {
    id = confluent_flink_compute_pool.flink_compute_pool.id
  }
  principal {
    id = confluent_service_account.sa_demo.id
  }
  statement  = <<EOF
  CREATE CONNECTION IF NOT EXISTS `patientdb-pg-connection`
  WITH (
    'type' = 'confluent_jdbc',
    'endpoint' = 'jdbc:postgresql://${aws_db_instance.postgres_db.address}:${aws_db_instance.postgres_db.port}/${aws_db_instance.postgres_db.db_name}',

    'username' = '${var.db_username}',
    'password' = '${var.db_password}'
  );
  EOF
  properties = {
    "sql.current-catalog"  = confluent_environment.env_demo.display_name
    "sql.current-database" = confluent_kafka_cluster.cluster_kafka_demo.display_name
  }

  rest_endpoint = data.confluent_flink_region.main.rest_endpoint
  credentials {
    key    = confluent_api_key.api_key_sa_demo_flink.id
    secret = confluent_api_key.api_key_sa_demo_flink.secret
  }

  lifecycle {
    prevent_destroy = false
  }
}

resource "confluent_flink_statement" "patient_table" {
  depends_on = [
     confluent_flink_compute_pool.flink_compute_pool,
    confluent_flink_statement.patientdb_connection
  ]   
  organization {
    id = data.confluent_organization.main.id
  } 
  environment {
    id = confluent_environment.env_demo.id 
  } 
  compute_pool {
    id = confluent_flink_compute_pool.flink_compute_pool.id
  }
  principal {
    id = confluent_service_account.sa_demo.id
  }
  statement  = <<EOF
  CREATE TABLE patients (
      patient_id INT,
      name       STRING,
      age        INT
    )
    WITH (
      'connector'                 = 'confluent-jdbc',
      'confluent-jdbc.connection' = 'patientdb-pg-connection',
      'confluent-jdbc.table-name' = 'patients'
    );
  EOF
  properties = {
    "sql.current-catalog"  = confluent_environment.env_demo.display_name
    "sql.current-database" = confluent_kafka_cluster.cluster_kafka_demo.display_name
  }

  rest_endpoint = data.confluent_flink_region.main.rest_endpoint
  credentials {
    key    = confluent_api_key.api_key_sa_demo_flink.id
    secret = confluent_api_key.api_key_sa_demo_flink.secret
  }

  lifecycle {
    prevent_destroy = false
  }
}

# # --------------------------------------------------------
# # Step 2: Enrich events with patient data
# # --------------------------------------------------------

resource "confluent_flink_statement" "enriched_events_feed" {
  depends_on = [
    confluent_flink_statement.patient_table,
    confluent_flink_compute_pool.flink_compute_pool,
    confluent_schema.events_value
  ]   
  organization {
    id = data.confluent_organization.main.id
  } 
  environment {
    id = confluent_environment.env_demo.id 
  } 
  compute_pool {
    id = confluent_flink_compute_pool.flink_compute_pool.id
  }
  principal {
    id = confluent_service_account.sa_demo.id
  }
  statement  = <<EOF

  CREATE TABLE enriched_events AS
  SELECT
    $rowtime as event_time,
    v.*,
    r.name,
    r.age
  FROM events v
  CROSS JOIN LATERAL TABLE(
    KEY_SEARCH_AGG(
      patients,
      DESCRIPTOR(patient_id),
      v.patient_id
    )
  ) AS T(search_results)
  CROSS JOIN UNNEST(T.search_results) AS r(patient_id, name, age);

  EOF
  properties = {
    "sql.current-catalog"  = confluent_environment.env_demo.display_name
    "sql.current-database" = confluent_kafka_cluster.cluster_kafka_demo.display_name
  }

  rest_endpoint = data.confluent_flink_region.main.rest_endpoint
  credentials {
    key    = confluent_api_key.api_key_sa_demo_flink.id
    secret = confluent_api_key.api_key_sa_demo_flink.secret
  }

  lifecycle {
    prevent_destroy = false
  }
}


# --------------------------------------------------------
# Step 3: remove anomalies from health events (ML_DETECT_ANOMALIES)
# --------------------------------------------------------
resource "confluent_flink_statement" "anomalies_detected" {
  depends_on = [
     confluent_flink_compute_pool.flink_compute_pool,
    confluent_flink_statement.enriched_events_feed
  ]   
  organization {
    id = data.confluent_organization.main.id
  } 
  environment {
    id = confluent_environment.env_demo.id 
  } 
  compute_pool {
    id = confluent_flink_compute_pool.flink_compute_pool.id
  }
  principal {
    id = confluent_service_account.sa_demo.id
  }
  statement  = <<EOF

CREATE TABLE enriched_events_flagged AS
WITH windowed_vitals AS (
    -- Step 1: Smooth data into 1-second ticks
    SELECT 
        patient_id,
        window_time AS event_timestamp,
        AVG(vitals.heart_rate) AS avg_heart_rate
    FROM TABLE(
        TUMBLE(TABLE events, DESCRIPTOR($rowtime), INTERVAL '1' SECOND)
    )
    GROUP BY patient_id, window_start, window_end, window_time
),
anomaly_detection AS (
    -- Step 2: Calculate anomaly scores
    SELECT 
        patient_id,
        event_timestamp,
        avg_heart_rate,
        ML_DETECT_ANOMALIES(
            avg_heart_rate, 
            event_timestamp, 
            JSON_OBJECT(
                'minTrainingSize' VALUE 30, 
                'confidencePercentage' VALUE 95.0
            )
        ) OVER (
            PARTITION BY patient_id 
            ORDER BY event_timestamp 
            RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS report
    FROM windowed_vitals
  ) 
  -- Step 3: Just emit data for further filtering/analysis
  SELECT 
      patient_id,
      event_timestamp,
      avg_heart_rate AS observed_value,
      report
  FROM anomaly_detection;

  EOF
  properties = {
    "sql.current-catalog"  = confluent_environment.env_demo.display_name
    "sql.current-database" = confluent_kafka_cluster.cluster_kafka_demo.display_name
  }

  rest_endpoint = data.confluent_flink_region.main.rest_endpoint
  credentials {
    key    = confluent_api_key.api_key_sa_demo_flink.id
    secret = confluent_api_key.api_key_sa_demo_flink.secret
  }

  lifecycle {
    prevent_destroy = false
  }
}

# --------------------------------------------------------
# Step 3: filter out anomalies
# --------------------------------------------------------

resource "confluent_flink_statement" "filtered_enriched_events" {
  depends_on = [
    confluent_flink_statement.anomalies_detected,
    confluent_flink_compute_pool.flink_compute_pool
  ]
  organization {
    id = data.confluent_organization.main.id
  }
  environment {
    id = confluent_environment.env_demo.id
  }
  compute_pool {
    id = confluent_flink_compute_pool.flink_compute_pool.id
  }
  principal {
    id = confluent_service_account.sa_demo.id
  }
  statement = <<EOF

  CREATE TABLE filtered_enriched_events AS
  SELECT
    *
  FROM enriched_events_flagged
  WHERE COALESCE(JSON_VALUE(report, '$.isAnomaly'), 'false') = 'false';

  EOF
  properties = {
    "sql.current-catalog"  = confluent_environment.env_demo.display_name
    "sql.current-database" = confluent_kafka_cluster.cluster_kafka_demo.display_name
  }

  rest_endpoint = data.confluent_flink_region.main.rest_endpoint
  credentials {
    key    = confluent_api_key.api_key_sa_demo_flink.id
    secret = confluent_api_key.api_key_sa_demo_flink.secret
  }

  lifecycle {
    prevent_destroy = false
  }
}

# --------------------------------------------------------
# Step 4: detect health alerts based on ML_FORECAST
# --------------------------------------------------------

resource "confluent_flink_statement" "heartbeat_alerts" {
  depends_on = [
    confluent_flink_statement.filtered_enriched_events,
    confluent_flink_compute_pool.flink_compute_pool 
  ]
  organization {
    id = data.confluent_organization.main.id
  }
  environment {
    id = confluent_environment.env_demo.id
  }
  compute_pool {
    id = confluent_flink_compute_pool.flink_compute_pool.id
  }
  principal {
    id = confluent_service_account.sa_demo.id
  }
  statement = <<EOF

  CREATE TABLE heartbeat_alerts AS
  WITH forecasted AS (
    SELECT
      patient_id,
      event_timestamp,
      observed_value,
      ML_FORECAST(
        observed_value,
        event_timestamp,
        JSON_OBJECT(
          'horizon' VALUE 1,
          'confidencePercentage' VALUE 95.0
        )
      ) OVER (
        PARTITION BY patient_id
        ORDER BY event_timestamp
        RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
      ) AS forecast_values
    FROM filtered_enriched_events
  )
  SELECT
    f.patient_id,
    f.event_timestamp,
    f.observed_value AS current_value,
    fc.forecast_value
  FROM forecasted AS f
  CROSS JOIN UNNEST(f.forecast_values) AS fc(
    forecast_timestamp,
    forecast_value,
    lower_bound,
    upper_bound,
    rmse,
    aic
  )
  WHERE fc.forecast_value < 40;

  EOF
  properties = {
    "sql.current-catalog"  = confluent_environment.env_demo.display_name
    "sql.current-database" = confluent_kafka_cluster.cluster_kafka_demo.display_name
  }

  rest_endpoint = data.confluent_flink_region.main.rest_endpoint
  credentials {
    key    = confluent_api_key.api_key_sa_demo_flink.id
    secret = confluent_api_key.api_key_sa_demo_flink.secret
  }

  lifecycle {
    prevent_destroy = false
  }
}


# --------------------------------------------------------
# Step N: push alerts to tableflow
# --------------------------------------------------------

