#!/bin/sh
# Reliable RabbitMQ cluster entrypoint for 3-node cluster
# Seed node: rabbit-1 (override via RABBITMQ_CLUSTER_WITH)
# This script is idempotent and safe for restarts.

set -eu

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

ensure_cookie() {
  # If RABBITMQ_COOKIE is provided (via .env), ensure the cookie file content and perms
  if [ "${RABBITMQ_COOKIE:-}" != "" ]; then
    COOKIE_FILE="/var/lib/rabbitmq/.erlang.cookie"
    # Create directory if missing (normally exists)
    mkdir -p "$(dirname "$COOKIE_FILE")"
    # Only update if contents differ or file missing
    if [ ! -s "$COOKIE_FILE" ] || ! grep -qx "$RABBITMQ_COOKIE" "$COOKIE_FILE" 2>/dev/null; then
      umask 077
      printf '%s' "$RABBITMQ_COOKIE" > "$COOKIE_FILE"
      chmod 400 "$COOKIE_FILE"
      log "Erlang cookie written to $COOKIE_FILE"
    else
      chmod 400 "$COOKIE_FILE" 2>/dev/null || true
      log "Erlang cookie already present"
    fi
  else
    log "WARNING: RABBITMQ_COOKIE not set; relying on existing cookie file"
  fi
}

wait_for_local() {
  # Wait until local node responds to ping
  # $1: max seconds (optional, default 60)
  MAX_WAIT=${1:-60}
  i=0
  while ! rabbitmq-diagnostics -q ping >/dev/null 2>&1; do
    i=$((i+1))
    if [ "$i" -ge "$MAX_WAIT" ]; then
      log "Timeout waiting for local RabbitMQ to be ready"
      return 1
    fi
    sleep 1
  done
  return 0
}

already_clustered_with_seed() {
  # Returns 0 if cluster_status shows seed node, else 1
  rabbitmqctl cluster_status 2>/dev/null | tr -d '\n' | grep -q "rabbit@${SEED_HOST}"
}

try_join_cluster() {
  # Stop app, attempt join with retries, then start app
  JOIN_RETRIES=${JOIN_RETRIES:-30}
  SLEEP_BETWEEN=${JOIN_RETRY_INTERVAL:-3}

  rabbitmqctl stop_app >/dev/null 2>&1 || true

  n=0
  while :; do
    if rabbitmqctl join_cluster "rabbit@${SEED_HOST}" >/dev/null 2>&1; then
      log "Successfully joined cluster rabbit@${SEED_HOST}"
      break
    fi
    n=$((n+1))
    if [ "$n" -ge "$JOIN_RETRIES" ]; then
      log "ERROR: Failed to join cluster rabbit@${SEED_HOST} after ${n} attempts"
      return 1
    fi
    log "Join attempt ${n} failed; retrying in ${SLEEP_BETWEEN}s..."
    sleep "$SLEEP_BETWEEN"
  done

  rabbitmqctl start_app >/dev/null 2>&1 || true
  return 0
}

main() {
  HOSTNAME=$(hostname -s 2>/dev/null || hostname)
  SEED_HOST=${RABBITMQ_CLUSTER_WITH:-rabbitmq-1}

  # Explicit nodename for clarity (RabbitMQ defaults to rabbit@<hostname>)
  export RABBITMQ_NODENAME="rabbit@${HOSTNAME}"

  ensure_cookie

  if [ "$HOSTNAME" = "$SEED_HOST" ]; then
    log "Starting SEED node: ${RABBITMQ_NODENAME}"
    exec rabbitmq-server
  fi

  log "Starting JOINER node: ${RABBITMQ_NODENAME}; will join rabbit@${SEED_HOST}"

  # Start in background to perform clustering steps
  rabbitmq-server -detached

  if ! wait_for_local 90; then
    log "ERROR: Local RabbitMQ did not become ready"
    exit 1
  fi

  if already_clustered_with_seed; then
    log "Node already part of cluster with seed rabbit@${SEED_HOST}; skipping join"
  else
    if ! try_join_cluster; then
      log "ERROR: Cluster join failed; proceeding to restart in foreground anyway"
    fi
  fi

  # Stop background instance and start in foreground as container process
  rabbitmqctl stop >/dev/null 2>&1 || true
  log "Starting RabbitMQ in foreground"
  exec rabbitmq-server
}

main "$@"
