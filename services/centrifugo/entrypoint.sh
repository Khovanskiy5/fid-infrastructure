#!/usr/bin/env sh
set -e

LOG_DIR="/var/log/centrifugo"
LOG_FILE="$LOG_DIR/centrifugo.log"
PIPE="/tmp/centrifugo-log.pipe"

# Ensure log directory and file exist
mkdir -p "$LOG_DIR"
: > "$LOG_FILE"

# Create a named pipe for duplicating output
[ -p "$PIPE" ] || mkfifo "$PIPE"

# Start tee in background to write to log file and stdout
# tee's stdout remains container stdout; using -a to append
tee -a "$LOG_FILE" < "$PIPE" &

# Exec Centrifugo with stdout+stderr redirected into the pipe
# Using exec to keep Centrifugo as PID 1 (proper signal handling and exit code)
exec sh -lc "exec centrifugo -c /etc/centrifugo/config.json -a 0.0.0.0 -p 8000 > '$PIPE' 2>&1"
