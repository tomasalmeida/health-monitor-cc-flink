FROM python:3.11-slim

WORKDIR /app

COPY health_simulator.py /app/health_simulator.py

RUN pip install --no-cache-dir "confluent-kafka[avro]"

CMD ["python", "health_simulator.py", "--config", "/app/config.json"]
