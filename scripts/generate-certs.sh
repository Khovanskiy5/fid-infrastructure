#!/usr/bin/env sh
# Generates self-signed TLS certificates for Nginx and MinIO
# and optionally uploads them to MinIO as objects.
#
# Usage:
#   sh scripts/generate-certs.sh               # generate only (default)
#   UPLOAD_TO_MINIO=1 sh scripts/generate-certs.sh  # also upload to MinIO if reachable
#   FORCE=1 sh scripts/generate-certs.sh       # regenerate even if files exist
#
set -eu

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NGINX_CERT_DIR="$PROJECT_DIR/services/nginx/certs"
MINIO_CERT_DIR="$PROJECT_DIR/services/minio/certs"
WORK_DIR="$PROJECT_DIR/.tmp/certs"

# Defaults (can be overridden via env or .env)
CERT_CN="localhost"
CERT_DAYS="825" # <= 825 keeps compatibility with some clients
MINIO_HOST="localhost"
MINIO_S3_PORT="9000"
MINIO_BUCKET="certs"

# Load .env if present to get MINIO_ROOT_USER/MINIO_ROOT_PASSWORD and others
if [ -f "$PROJECT_DIR/.env" ]; then
  # shellcheck disable=SC3040
  set -a
  . "$PROJECT_DIR/.env"
  # shellcheck disable=SC3040
  set +a
fi

# Allow overrides
CERT_CN=${CERT_CN:-${TLS_CERT_CN:-localhost}}
CERT_DAYS=${CERT_DAYS:-${TLS_CERT_DAYS:-825}}
MINIO_ROOT_USER=${MINIO_ROOT_USER:-minioadmin}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD:-minioadminpass}
MINIO_BUCKET=${MINIO_BUCKET:-certs}
MINIO_HOST=${MINIO_HOST:-localhost}
MINIO_S3_PORT=${MINIO_S3_PORT:-9000}

UPLOAD_TO_MINIO=${UPLOAD_TO_MINIO:-0}
FORCE=${FORCE:-0}

info() { printf "[info] %s\n" "$*"; }
ok()   { printf "[ok] %s\n" "$*"; }
warn() { printf "[warn] %s\n" "$*"; }
err()  { printf "[err] %s\n" "$*" 1>&2; }

# Ensure temporary working directory is removed on exit (success or error)
cleanup() {
  # Safety: only remove if WORK_DIR is under project .tmp
  if [ -n "${WORK_DIR:-}" ]; then
    case "$WORK_DIR" in
      "$PROJECT_DIR"/.tmp/*)
        [ -d "$WORK_DIR" ] && rm -rf "$WORK_DIR"
        ;;
      *)
        warn "Refusing to remove unexpected WORK_DIR='$WORK_DIR'"
        ;;
    esac
  fi
}
trap 'cleanup' EXIT INT TERM

mkdir -p "$NGINX_CERT_DIR" "$MINIO_CERT_DIR" "$WORK_DIR"

MINIO_PUBLIC_CRT="$MINIO_CERT_DIR/public.crt"
MINIO_PRIVATE_KEY="$MINIO_CERT_DIR/private.key"
NGINX_SERVER_CRT="$NGINX_CERT_DIR/server.crt"
NGINX_SERVER_KEY="$NGINX_CERT_DIR/server.key"

need_generate=0
if [ "$FORCE" = "1" ]; then
  need_generate=1
else
  # If any of the four files missing -> generate
  for f in "$MINIO_PUBLIC_CRT" "$MINIO_PRIVATE_KEY" "$NGINX_SERVER_CRT" "$NGINX_SERVER_KEY"; do
    if [ ! -s "$f" ]; then need_generate=1; break; fi
  done
fi

if [ "$need_generate" = "1" ]; then
  info "Generating self-signed certificate (CN=$CERT_CN, days=$CERT_DAYS)"
  OPENSSL_CNF="$WORK_DIR/openssl.cnf"
  cat > "$OPENSSL_CNF" <<EOF
[ req ]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[ req_distinguished_name ]
C = RU
ST = Moscow
L = Moscow
O = LocalDev
OU = Infrastructure
CN = $CERT_CN

[ v3_req ]
subjectAltName = @alt_names
basicConstraints = CA:false
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth

[ alt_names ]
DNS.1 = localhost
DNS.2 = minio
DNS.3 = nginx
IP.1 = 127.0.0.1
EOF

  PRIV_KEY="$WORK_DIR/tls.key"
  CERT_PEM="$WORK_DIR/tls.crt"

  # Generate key and self-signed certificate with SAN
  openssl req -x509 -nodes -newkey rsa:2048 -keyout "$PRIV_KEY" -out "$CERT_PEM" -days "$CERT_DAYS" -config "$OPENSSL_CNF" >/dev/null 2>&1 || {
    err "OpenSSL failed to generate certificate"; exit 1; }

  # Copy to MinIO expected filenames
  cp "$CERT_PEM" "$MINIO_PUBLIC_CRT"
  cp "$PRIV_KEY" "$MINIO_PRIVATE_KEY"
  chmod 600 "$MINIO_PRIVATE_KEY" || true
  chmod 644 "$MINIO_PUBLIC_CRT" || true

  # Copy to Nginx expected filenames
  cp "$CERT_PEM" "$NGINX_SERVER_CRT"
  cp "$PRIV_KEY" "$NGINX_SERVER_KEY"
  chmod 600 "$NGINX_SERVER_KEY" || true
  chmod 644 "$NGINX_SERVER_CRT" || true

  ok "Certificates generated:"
  echo "  MinIO:   $MINIO_PUBLIC_CRT , $MINIO_PRIVATE_KEY"
  echo "  Nginx:   $NGINX_SERVER_CRT , $NGINX_SERVER_KEY"
else
  ok "Certificates already exist. Use FORCE=1 to regenerate."
fi

# Optional upload into a MinIO bucket as objects
if [ "$UPLOAD_TO_MINIO" = "1" ]; then
  info "Uploading certs to MinIO bucket '$MINIO_BUCKET' if MinIO is reachable..."

  # Quick readiness check
  MINIO_URL="http://$MINIO_HOST:$MINIO_S3_PORT/minio/health/ready"
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 2 "$MINIO_URL" >/dev/null 2>&1 || reachable=0
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 2 -O - "$MINIO_URL" >/dev/null 2>&1 || reachable=0
  else
    warn "Neither curl nor wget found; skipping reachability check."
  fi
  reachable=${reachable:-1}

  if [ "$reachable" = "1" ]; then
    # Use minio/mc in a disposable container within the docker network 'infrastructure'
    # We address MinIO as http://minio:9000 inside the network
    if command -v docker >/dev/null 2>&1; then
      info "Using minio/mc container to upload files to bucket '$MINIO_BUCKET'"
      docker run --rm \
        --network infrastructure \
        -v "$MINIO_CERT_DIR":"/host/minio-certs":ro \
        -v "$NGINX_CERT_DIR":"/host/nginx-certs":ro \
        minio/mc \
        sh -c "mc alias set local http://minio:9000 '$MINIO_ROOT_USER' '$MINIO_ROOT_PASSWORD' >/dev/null && \
               mc mb -p --ignore-existing local/$MINIO_BUCKET >/dev/null 2>&1 || true && \
               mc cp --attr 'content-type=application/x-x509-ca-cert' /host/minio-certs/public.crt local/$MINIO_BUCKET/minio-public.crt && \
               mc cp --attr 'content-type=application/octet-stream' /host/minio-certs/private.key local/$MINIO_BUCKET/minio-private.key && \
               mc cp --attr 'content-type=application/x-x509-ca-cert' /host/nginx-certs/server.crt local/$MINIO_BUCKET/nginx-server.crt && \
               mc cp --attr 'content-type=application/octet-stream' /host/nginx-certs/server.key local/$MINIO_BUCKET/nginx-server.key"
      ok "Uploaded certs to MinIO bucket '$MINIO_BUCKET'"
    else
      warn "Docker not available; cannot run minio/mc. Skipping upload."
    fi
  else
    warn "MinIO not reachable at $MINIO_URL. Start the stack (make up) and rerun: UPLOAD_TO_MINIO=1 make certs"
  fi
else
  info "Skipping upload. To upload into MinIO after 'make up': UPLOAD_TO_MINIO=1 make certs"
fi

exit 0
