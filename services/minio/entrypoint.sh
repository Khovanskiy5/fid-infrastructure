#!/usr/bin/env sh
set -e

mkdir -p /var/log/minio

# Log file path (mounted to ./logs/minio on host)
LOG_FILE="/var/log/minio/minio.log"
# Ensure file exists and is writable
: > "$LOG_FILE" || true

# Run MinIO server and redirect logs to file
exec minio server /data --console-address ":9001" >> "$LOG_FILE" 2>&1
