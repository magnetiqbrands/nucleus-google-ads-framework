#!/bin/bash
# Standard entrypoint script for Nucleus Ads API
# Use this for non-Vault deployments with environment variables

set -euo pipefail

echo "==> Nucleus Google Ads API - Starting"

# Wait for Redis if configured
if [[ -n "${REDIS_URL:-}" ]]; then
    echo "==> Waiting for Redis at $REDIS_URL"

    # Extract host and port from Redis URL
    REDIS_HOST=$(echo "$REDIS_URL" | sed -n 's#.*://\([^:]*\).*#\1#p')
    REDIS_PORT=$(echo "$REDIS_URL" | sed -n 's#.*:\([0-9]*\).*#\1#p')
    REDIS_PORT=${REDIS_PORT:-6379}

    timeout=30
    while ! nc -z "$REDIS_HOST" "$REDIS_PORT" 2>/dev/null; do
        timeout=$((timeout - 1))
        if [[ $timeout -le 0 ]]; then
            echo "ERROR: Redis not available after 30 seconds"
            exit 1
        fi
        echo "    Waiting for Redis... ($timeout seconds remaining)"
        sleep 1
    done

    echo "    Redis is ready"
fi

# Wait for PostgreSQL if configured
if [[ -n "${DATABASE_URL:-}" ]]; then
    echo "==> Waiting for PostgreSQL"

    # Extract connection details (basic parsing)
    PG_HOST=$(echo "$DATABASE_URL" | sed -n 's#.*@\([^:/]*\).*#\1#p')
    PG_PORT=$(echo "$DATABASE_URL" | sed -n 's#.*:\([0-9]*\)/.*#\1#p')
    PG_PORT=${PG_PORT:-5432}

    timeout=30
    while ! nc -z "$PG_HOST" "$PG_PORT" 2>/dev/null; do
        timeout=$((timeout - 1))
        if [[ $timeout -le 0 ]]; then
            echo "WARNING: PostgreSQL not available after 30 seconds (continuing anyway)"
            break
        fi
        echo "    Waiting for PostgreSQL... ($timeout seconds remaining)"
        sleep 1
    done

    if nc -z "$PG_HOST" "$PG_PORT" 2>/dev/null; then
        echo "    PostgreSQL is ready"
    fi
fi

echo "==> Environment: ${APP_ENV:-development}"
echo "==> Log level: ${APP_LOG_LEVEL:-INFO}"
echo ""
echo "==> Starting application: $@"
echo ""

# Execute the command
exec "$@"
