FROM python:3.11-slim

WORKDIR /app

# Install necessary system tools for VPN metrics collection
RUN apt-get update && apt-get install -y --no-install-recommends \
    iputils-ping \
    iproute2 \
    procps \
    && rm -rf /var/lib/apt/lists/*

# Copy exporter script
COPY vpn_exporter.py /app/
COPY requirements.txt /app/

# Install Python dependencies (minimal - only stdlib used)
RUN pip install --no-cache-dir -r requirements.txt || true

# Expose metrics port
EXPOSE 9100

# Run exporter
CMD ["python", "-u", "vpn_exporter.py"]
