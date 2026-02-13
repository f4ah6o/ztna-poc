FROM python:3.12-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    iproute2 \
    iptables \
    iputils-ping \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir uv \
  && uv pip install --system --no-cache -r /app/requirements.txt

COPY src /app/src
COPY config.yaml /app/config.yaml
ENV PYTHONPATH=/app/src

CMD ["sleep", "infinity"]
