"""
Health signal simulator inspired by the connector_datagen schema.
Generates realistic-looking time series with circadian sine drift + Brownian jitter.
Outputs JSON lines to stdout; pipe to Kafka producer if desired.
"""
import argparse
import json
import math
import random
import os
import string
import sys
import time
from typing import Dict, Tuple

# Fixed choices to mirror the Datagen schema options
PATIENT_IDS = list(range(1, 11))
DEVICE_TYPES = ["wearable_v4", "wearable_v3", "wearable_v2"]
SENSOR_STATUS = ["stable", "noisy", "offline"]
BATTERY_LEVELS = [5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 90, 95, 100]
HEART_RATE_OPTIONS = [55, 60, 65, 70, 75, 80, 85, 90, 95, 100, 105, 110, 115, 120, 125, 130, 135, 140, 145, 150]
HEART_RATE_LOW_OPTIONS = [20, 25, 30, 35, 40, 45, 50]
HEART_RATE_ALLOWED = sorted(set(HEART_RATE_OPTIONS + HEART_RATE_LOW_OPTIONS))
SPO2_OPTIONS = [82, 84, 86, 88, 90, 92, 94, 96, 98, 100]
SYSTOLIC_OPTIONS = [90, 95, 100, 105, 110, 115, 120, 125, 130, 135, 140, 145, 150, 155, 160, 165, 170, 175, 180]
DIASTOLIC_OPTIONS = [60, 65, 70, 75, 80, 85, 90, 95, 100, 105, 110, 115, 120]
BODY_TEMP_OPTIONS = [35.0, 35.5, 36.0, 36.5, 37.0, 37.5, 38.0, 38.5, 39.0, 39.5, 40.0]
DEFAULT_CONFIG_PATH = "config.json"
AVRO_SCHEMA = {
    "namespace": "health_events",
    "name": "health_event",
    "type": "record",
    "fields": [
        {"name": "event_id", "type": "string"},
        {"name": "patient_id", "type": "int"},
        {
            "name": "device_metadata",
            "type": {
                "type": "record",
                "name": "device_metadata",
                "fields": [
                    {"name": "device_type", "type": "string"},
                    {"name": "battery_level", "type": "int"},
                    {"name": "sensor_status", "type": "string"}
                ]
            }
        },
        {
            "name": "vitals",
            "type": {
                "type": "record",
                "name": "vitals",
                "fields": [
                    {"name": "heart_rate", "type": "int"},
                    {"name": "blood_oxygen_spO2", "type": "int"},
                    {
                        "name": "blood_pressure",
                        "type": {
                            "type": "record",
                            "name": "blood_pressure",
                            "fields": [
                                {"name": "systolic", "type": "int"},
                                {"name": "diastolic", "type": "int"}
                            ]
                        }
                    },
                    {"name": "body_temperature_c", "type": "float"}
                ]
            }
        }
    ]
}


def short_id(length: int = 12) -> str:
    """Random alphanumeric ID similar to the connector's 12-char string."""
    alphabet = string.ascii_lowercase + string.digits
    return "".join(random.choice(alphabet) for _ in range(length))


class BrownianDrift:
    """Maintains correlated noise so consecutive points look like a real trace."""

    def __init__(self, volatility: float, clamp: Tuple[float, float]):
        self.volatility = volatility
        self.clamp_min, self.clamp_max = clamp
        self.state = 0.0

    def step(self) -> float:
        self.state += random.gauss(0.0, self.volatility)
        self.state = max(self.clamp_min, min(self.state, self.clamp_max))
        return self.state


def circadian_sine(now_s: float, period_s: float, amplitude: float) -> float:
    phase = 2 * math.pi * (now_s % period_s) / period_s
    return amplitude * math.sin(phase)


def choose_nearest(target: float, options) -> float:
    """Pick the closest allowed discrete value from the Datagen options."""
    return min(options, key=lambda x: abs(x - target))


def apply_patient_one_bradycardia(event: Dict, elapsed: float) -> Dict:
    """Special-case patient 1: progressively slow HR toward ~20 bpm and slightly depress SpO2."""
    if event["patient_id"] != 1:
        return event

    onset_s = 30.0
    slope_window_s = 180.0  # reach floor around 3 minutes after onset
    if elapsed < onset_s:
        return event

    phase = min(1.0, (elapsed - onset_s) / slope_window_s)
    target_hr = 20.0 + (45.0 * (1.0 - phase))  # glides from ~65 bpm down to ~20 bpm
    target_hr += random.gauss(0.0, 1.5)
    event["vitals"]["heart_rate"] = choose_nearest(target_hr, HEART_RATE_ALLOWED)

    spo2_drop = 6.0 * phase
    spo2_target = event["vitals"]["blood_oxygen_spO2"] - spo2_drop
    event["vitals"]["blood_oxygen_spO2"] = choose_nearest(max(min(SPO2_OPTIONS), spo2_target), SPO2_OPTIONS)

    return event


def load_config(path: str) -> Dict:
    if not path:
        return {}
    if not os.path.exists(path):
        return {}
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def build_producer(kafka_cfg: Dict):
    try:
        from confluent_kafka import Producer
    except ImportError as exc:
        raise SystemExit("confluent_kafka is required: pip install confluent-kafka") from exc

    cfg = dict(kafka_cfg)
    topic = cfg.pop("topic", None)
    if topic is None:
        raise SystemExit("Kafka config must include a 'topic' field")
    return topic, Producer(cfg)


def build_avro_producer(kafka_cfg: Dict):
    try:
        from confluent_kafka.serialization import StringSerializer
        from confluent_kafka.schema_registry import SchemaRegistryClient
        from confluent_kafka.schema_registry.avro import AvroSerializer
        from confluent_kafka import SerializingProducer
    except ImportError as exc:
        raise SystemExit("confluent_kafka with schema-registry support is required") from exc

    cfg = dict(kafka_cfg)
    topic = cfg.pop("topic", None)
    if topic is None:
        raise SystemExit("Kafka config must include a 'topic' field")

    # Extract SR config - SchemaRegistryClient expects different property names
    sr_conf_dict = cfg.copy()
    sr_conf_final = {}
    
    if "schema.registry.url" in sr_conf_dict:
        sr_conf_final["url"] = sr_conf_dict.pop("schema.registry.url")
    else:
        raise SystemExit("schema.registry.url is required for Avro output")
    
    # Map Kafka properties to SchemaRegistry client properties
    if "basic.auth.user.info" in sr_conf_dict:
        sr_conf_final["basic.auth.user.info"] = sr_conf_dict.pop("basic.auth.user.info")
    if "basic.auth.credentials.source" in sr_conf_dict:
        sr_conf_dict.pop("basic.auth.credentials.source")  # Remove from kafka config
    if "bearer.auth.token" in sr_conf_dict:
        sr_conf_final["bearer.auth.token"] = sr_conf_dict.pop("bearer.auth.token")
    
    sr_client = SchemaRegistryClient(sr_conf_final)
    
    # Remove SR-specific keys from kafka config
    cfg = {k: v for k, v in cfg.items() if not k.startswith("schema.registry.") and k != "basic.auth.credentials.source" and k != "basic.auth.user.info" and k != "bearer.auth.token"}
    schema_str = json.dumps(AVRO_SCHEMA)
    value_serializer = AvroSerializer(sr_client, schema_str)
    producer = SerializingProducer({**cfg, "value.serializer": value_serializer, "key.serializer": StringSerializer()})
    return topic, producer


def make_event(t0: float, patient_id: int, brownian: Dict[str, BrownianDrift]) -> Dict:
    now = time.time()
    elapsed = now - t0

    # Circadian components (24h period ~ 86400s)
    hr_base = 82  # resting average
    hr_amp = 12   # day-night swing
    temp_base = 36.7
    temp_amp = 0.5

    hr_val = hr_base + circadian_sine(now, 86400, hr_amp) + brownian["hr"].step()
    temp_val = temp_base + circadian_sine(now, 86400, temp_amp) + brownian["temp"].step()

    systolic_base = 120
    diastolic_base = 78
    bp_amp = 8
    systolic_val = systolic_base + circadian_sine(now, 86400, bp_amp) + brownian["sys"].step()
    diastolic_val = diastolic_base + circadian_sine(now, 86400, bp_amp * 0.6) + brownian["dia"].step()

    spo2_base = 96
    spo2_val = spo2_base + circadian_sine(now, 86400, 1.0) + brownian["spo2"].step()

    battery = max(5, min(100, 100 - int(elapsed / 300) - random.randint(0, 2)))

    event = {
        "event_id": short_id(),
        "patient_id": patient_id,
        "device_metadata": {
            "device_type": random.choice(DEVICE_TYPES),
            "battery_level": choose_nearest(battery, BATTERY_LEVELS),
            "sensor_status": random.choices(SENSOR_STATUS, weights=[0.8, 0.15, 0.05])[0],
        },
        "vitals": {
            "heart_rate": choose_nearest(hr_val, HEART_RATE_ALLOWED),
            "blood_oxygen_spO2": choose_nearest(spo2_val, SPO2_OPTIONS),
            "blood_pressure": {
                "systolic": choose_nearest(systolic_val, SYSTOLIC_OPTIONS),
                "diastolic": choose_nearest(diastolic_val, DIASTOLIC_OPTIONS),
            },
            "body_temperature_c": choose_nearest(temp_val, BODY_TEMP_OPTIONS),
        },
    }
    return apply_patient_one_bradycardia(event, elapsed)


def main() -> None:
    parser = argparse.ArgumentParser(description="Health data simulator (sine + Brownian noise)")
    parser.add_argument("--interval", type=float, default=None, help="Seconds between events")
    parser.add_argument("--duration", type=float, default=None, help="Run duration in seconds (0=infinite)")
    parser.add_argument("--config", type=str, default=DEFAULT_CONFIG_PATH, help="Path to JSON config file")
    parser.add_argument("--stdout", action="store_true", help="Force stdout output even if Kafka config is present")
    args = parser.parse_args()

    cfg = load_config(args.config)
    interval = args.interval if args.interval is not None else cfg.get("interval", 0.5)
    duration = args.duration if args.duration is not None else cfg.get("duration", 0.0)

    kafka_cfg = cfg.get("kafka") or {}
    kafka_topic = kafka_cfg.get("topic") or cfg.get("topic")
    producer = None
    is_avro = False
    if kafka_cfg and not args.stdout:
        if "schema.registry.url" in kafka_cfg:
            kafka_topic, producer = build_avro_producer(kafka_cfg)
            is_avro = True
        else:
            kafka_topic, producer = build_producer(kafka_cfg)

    t0 = time.time()
    # Create separate Brownian drift state for each patient
    brownian_per_patient = {}
    for patient_id in PATIENT_IDS:
        brownian_per_patient[patient_id] = {
            "hr": BrownianDrift(volatility=1.5, clamp=(-6, 6)),
            "temp": BrownianDrift(volatility=0.05, clamp=(-0.4, 0.4)),
            "sys": BrownianDrift(volatility=2.5, clamp=(-12, 12)),
            "dia": BrownianDrift(volatility=1.5, clamp=(-8, 8)),
            "spo2": BrownianDrift(volatility=0.6, clamp=(-3, 3)),
        }

    end_time = t0 + duration if duration > 0 else None
    try:
        while True:
            if end_time and time.time() >= end_time:
                break
            # Generate one event per patient
            for patient_id in PATIENT_IDS:
                event = make_event(t0, patient_id, brownian_per_patient[patient_id])
                payload = json.dumps(event)
                if producer:
                    if is_avro:
                        # SerializingProducer expects dict; Avro serializer handles encoding
                        producer.produce(kafka_topic, value=event)
                    else:
                        producer.produce(kafka_topic, value=payload.encode("utf-8"))
                    producer.poll(0)
                else:
                    sys.stdout.write(payload + "\n")
                    sys.stdout.flush()
            time.sleep(interval)
    except KeyboardInterrupt:
        pass
    finally:
        if producer:
            producer.flush()


if __name__ == "__main__":
    main()
