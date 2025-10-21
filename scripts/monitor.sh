#!/bin/bash
# Operations Monitoring Script
# Monitor Nucleus Google Ads API health and services

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
WATCH_MODE="${WATCH_MODE:-false}"
WATCH_INTERVAL="${WATCH_INTERVAL:-5}"
API_URL="${API_URL:-http://localhost:8000}"
SHOW_LOGS="${SHOW_LOGS:-false}"
LOG_LINES="${LOG_LINES:-50}"

# Helper functions
header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

section() {
    echo ""
    echo -e "${GREEN}==> $1${NC}"
}

status_ok() {
    echo -e "${GREEN}✓${NC} $1"
}

status_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

status_error() {
    echo -e "${RED}✗${NC} $1"
}

# Clear screen for watch mode
if [[ "$WATCH_MODE" == "true" ]]; then
    clear
fi

# Display header
header "Nucleus Google Ads API - Operations Monitor"
echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# 1. Docker Container Status
section "Docker Container Status"
if docker ps --filter name=nucleus-ads-api --format '{{.Names}}' | grep -q nucleus-ads-api; then
    CONTAINER_STATUS=$(docker ps --filter name=nucleus-ads-api --format '{{.Status}}')
    CONTAINER_NAME=$(docker ps --filter name=nucleus-ads-api --format '{{.Names}}')
    status_ok "Container running: $CONTAINER_NAME"
    echo "  Status: $CONTAINER_STATUS"

    # Container resource usage
    STATS=$(docker stats --no-stream --format "{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}" $CONTAINER_NAME)
    CPU=$(echo "$STATS" | awk '{print $1}')
    MEM=$(echo "$STATS" | awk '{print $2" "$3}')
    NET=$(echo "$STATS" | awk '{print $4" "$5}')

    echo "  CPU: $CPU"
    echo "  Memory: $MEM"
    echo "  Network: $NET"
else
    status_error "Container not running"
fi

# 2. Redis Status
section "Redis Status"
if command -v redis-cli &> /dev/null; then
    if redis-cli ping > /dev/null 2>&1; then
        status_ok "Redis responding"

        # Get Redis info
        REDIS_VERSION=$(redis-cli INFO SERVER | grep redis_version | cut -d: -f2 | tr -d '\r')
        REDIS_MEM=$(redis-cli INFO MEMORY | grep used_memory_human | cut -d: -f2 | tr -d '\r')
        REDIS_KEYS=$(redis-cli DBSIZE | awk '{print $2}')
        REDIS_CONNECTED=$(redis-cli INFO CLIENTS | grep connected_clients | cut -d: -f2 | tr -d '\r')

        echo "  Version: $REDIS_VERSION"
        echo "  Memory: $REDIS_MEM"
        echo "  Keys: $REDIS_KEYS"
        echo "  Clients: $REDIS_CONNECTED"
    else
        status_error "Redis not responding"
    fi
else
    status_warn "redis-cli not installed"
fi

# 3. API Health Check
section "API Health Status"
HEALTH_RESPONSE=$(curl -sf $API_URL/health 2>/dev/null || echo '{"status":"unreachable"}')
HEALTH_STATUS=$(echo "$HEALTH_RESPONSE" | jq -r '.status' 2>/dev/null || echo "unreachable")

if [[ "$HEALTH_STATUS" == "healthy" ]]; then
    status_ok "API healthy"

    VERSION=$(echo "$HEALTH_RESPONSE" | jq -r '.version')
    echo "  Version: $VERSION"

    # Components
    REDIS_OK=$(echo "$HEALTH_RESPONSE" | jq -r '.components.redis')
    SCHEDULER_OK=$(echo "$HEALTH_RESPONSE" | jq -r '.components.scheduler')

    if [[ "$REDIS_OK" == "true" ]]; then
        echo "  Redis: ✓"
    else
        echo "  Redis: ✗"
    fi

    if [[ "$SCHEDULER_OK" == "true" ]]; then
        echo "  Scheduler: ✓"
    else
        echo "  Scheduler: ✗"
    fi
else
    status_error "API unhealthy or unreachable"
fi

# 4. Nginx Status (if installed)
section "Nginx Status"
if command -v nginx &> /dev/null; then
    if systemctl is-active --quiet nginx; then
        status_ok "Nginx running"

        # Get Nginx version
        NGINX_VERSION=$(nginx -v 2>&1 | cut -d/ -f2)
        echo "  Version: $NGINX_VERSION"

        # Check if our site is enabled
        if [[ -L /etc/nginx/sites-enabled/nucleus-api-test ]] || [[ -L /etc/nginx/sites-enabled/nucleus-ads-api ]]; then
            echo "  Site: Enabled"
        else
            echo "  Site: Not enabled"
        fi
    else
        status_warn "Nginx installed but not running"
    fi
else
    status_warn "Nginx not installed"
fi

# 5. Disk Space
section "Disk Space"
DISK_USAGE=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')
DISK_AVAIL=$(df -h / | awk 'NR==2 {print $4}')

if [[ $DISK_USAGE -lt 80 ]]; then
    status_ok "Disk space OK (${DISK_USAGE}% used, ${DISK_AVAIL} available)"
elif [[ $DISK_USAGE -lt 90 ]]; then
    status_warn "Disk space moderate (${DISK_USAGE}% used, ${DISK_AVAIL} available)"
else
    status_error "Disk space critical (${DISK_USAGE}% used, ${DISK_AVAIL} available)"
fi

# 6. Memory Usage
section "System Memory"
MEM_TOTAL=$(free -h | awk 'NR==2 {print $2}')
MEM_USED=$(free -h | awk 'NR==2 {print $3}')
MEM_FREE=$(free -h | awk 'NR==2 {print $4}')
MEM_PERCENT=$(free | awk 'NR==2 {printf "%.0f", $3/$2 * 100}')

if [[ $MEM_PERCENT -lt 80 ]]; then
    status_ok "Memory OK (${MEM_PERCENT}% used)"
elif [[ $MEM_PERCENT -lt 90 ]]; then
    status_warn "Memory moderate (${MEM_PERCENT}% used)"
else
    status_error "Memory critical (${MEM_PERCENT}% used)"
fi

echo "  Total: $MEM_TOTAL"
echo "  Used: $MEM_USED"
echo "  Free: $MEM_FREE"

# 7. Recent Errors (if show_logs enabled)
if [[ "$SHOW_LOGS" == "true" ]]; then
    section "Recent Container Logs (last $LOG_LINES lines)"
    if docker ps --filter name=nucleus-ads-api --format '{{.Names}}' | grep -q nucleus-ads-api; then
        CONTAINER_NAME=$(docker ps --filter name=nucleus-ads-api --format '{{.Names}}')
        docker logs --tail $LOG_LINES $CONTAINER_NAME 2>&1 | tail -20
    fi
fi

# 8. SSL Certificate Status (if Nginx with SSL)
section "SSL Certificate Status"
if [[ -d /etc/letsencrypt/live ]]; then
    DOMAINS=$(find /etc/letsencrypt/live -maxdepth 1 -mindepth 1 -type d ! -name 'README' -exec basename {} \;)

    for DOMAIN in $DOMAINS; do
        if [[ -f "/etc/letsencrypt/live/$DOMAIN/cert.pem" ]]; then
            EXPIRY=$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/$DOMAIN/cert.pem" | cut -d= -f2)
            EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s)
            NOW_EPOCH=$(date +%s)
            DAYS_LEFT=$(( ($EXPIRY_EPOCH - $NOW_EPOCH) / 86400 ))

            if [[ $DAYS_LEFT -gt 30 ]]; then
                status_ok "$DOMAIN: ${DAYS_LEFT} days until expiry"
            elif [[ $DAYS_LEFT -gt 7 ]]; then
                status_warn "$DOMAIN: ${DAYS_LEFT} days until expiry"
            else
                status_error "$DOMAIN: ${DAYS_LEFT} days until expiry (renewal needed!)"
            fi
        fi
    done
else
    status_warn "No SSL certificates found"
fi

# Footer
echo ""
if [[ "$WATCH_MODE" == "true" ]]; then
    echo "Refreshing every ${WATCH_INTERVAL}s... (Ctrl+C to stop)"
    sleep $WATCH_INTERVAL
    exec $0
else
    echo "To run in watch mode: WATCH_MODE=true $0"
    echo "To show logs: SHOW_LOGS=true $0"
fi
