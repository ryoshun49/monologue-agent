#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# entrypoint.sh — Setup cron and run foreground
# ============================================================

echo "[entrypoint] Monologue Agent starting..."
echo "[entrypoint] HEARTBEAT_INTERVAL_MIN=${HEARTBEAT_INTERVAL_MIN:-30}"
echo "[entrypoint] MAX_BUDGET_USD=${MAX_BUDGET_USD:-0.30}"

# Ensure data directories exist
mkdir -p /app/data/{memory,episodes,monologues}

# Initialize memory files if missing
[ -f /app/data/memory/short-term.md ] || echo "# Short-term Memory" > /app/data/memory/short-term.md
[ -f /app/data/memory/long-term.md ] || echo "# Long-term Memory" > /app/data/memory/long-term.md

# Build environment string for cron jobs
ENV_VARS="DATA_DIR=/app/data CONFIG_DIR=/app/config"
ENV_VARS="$ENV_VARS HEARTBEAT_INTERVAL_MIN=${HEARTBEAT_INTERVAL_MIN:-30}"
ENV_VARS="$ENV_VARS MAX_BUDGET_USD=${MAX_BUDGET_USD:-0.30}"
ENV_VARS="$ENV_VARS CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-/app/auth/.claude}"
ENV_VARS="$ENV_VARS PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ENV_VARS="$ENV_VARS HOME=/root"

# Create cron schedule
INTERVAL="${HEARTBEAT_INTERVAL_MIN:-30}"
CRONTAB_FILE="/etc/cron.d/monologue"

cat > "$CRONTAB_FILE" << CRON
# Heartbeat: every ${INTERVAL} minutes
*/${INTERVAL} * * * * root $ENV_VARS /app/scripts/heartbeat.sh >> /proc/1/fd/1 2>&1

# Memory distillation: every 6 hours
0 */6 * * * root $ENV_VARS /app/scripts/distill.sh >> /proc/1/fd/1 2>&1

CRON

chmod 0644 "$CRONTAB_FILE"

echo "[entrypoint] Cron schedule installed:"
cat "$CRONTAB_FILE"

# Run first heartbeat immediately
echo "[entrypoint] Running initial heartbeat..."
/app/scripts/heartbeat.sh || echo "[entrypoint] Initial heartbeat failed (may be expected on first run)"

# Start cron in foreground
echo "[entrypoint] Starting cron daemon..."
exec cron -f
