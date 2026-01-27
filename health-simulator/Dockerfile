FROM python:3.11-slim

WORKDIR /app

COPY health-simulator/health_simulator.py /app/health_simulator.py
COPY config.json /app/config.json

RUN pip install --no-cache-dir "confluent-kafka[avro]"

CMD ["python", "health_simulator.py", "--config", "/app/config.json"]
