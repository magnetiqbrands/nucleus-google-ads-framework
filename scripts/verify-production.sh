#!/bin/bash
# Production Deployment Verification Script
# Verifies all components of a production deployment

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
DOMAIN="${DOMAIN:-example.com}"
API_URL="${API_URL:-https://$DOMAIN}"
VAULT_ADDR="${VAULT_ADDR:-}"
SKIP_VAULT="${SKIP_VAULT:-false}"
SKIP_SSL="${SKIP_SSL:-false}"

CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_TOTAL=0

# Helper functions
check_start() {
    echo ""
    echo -e "${BLUE}==> $1${NC}"
    CHECKS_TOTAL=$((CHECKS_TOTAL + 1))
}

check_pass() {
    echo -e "${GREEN}✓${NC} $1"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
}

check_fail() {
    echo -e "${RED}✗${NC} $1"
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
}

check_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

check_info() {
    echo "  $1"
}

# Header
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Production Deployment Verification${NC}"
echo -e "${BLUE}========================================${NC}"
echo "Domain: $DOMAIN"
echo "API URL: $API_URL"
echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# Check 1: Docker Container Status
check_start "Check 1: Docker Container Running"

if docker ps --filter name=nucleus-ads-api --format '{{.Names}}' | grep -q nucleus-ads-api; then
    CONTAINER_NAME=$(docker ps --filter name=nucleus-ads-api --format '{{.Names}}' | head -1)
    CONTAINER_STATUS=$(docker ps --filter name=$CONTAINER_NAME --format '{{.Status}}')

    if echo "$CONTAINER_STATUS" | grep -q "Up"; then
        check_pass "Container '$CONTAINER_NAME' is running"
        check_info "Status: $CONTAINER_STATUS"

        # Check if healthy
        if echo "$CONTAINER_STATUS" | grep -q "healthy"; then
            check_pass "Container is healthy"
        else
            check_warn "Container health check not available or unhealthy"
        fi
    else
        check_fail "Container exists but not running: $CONTAINER_STATUS"
    fi
else
    check_fail "No nucleus-ads-api container found"
fi

# Check 2: Vault Entrypoint Completion
check_start "Check 2: Vault Entrypoint Completed"

if [[ "$SKIP_VAULT" == "true" ]]; then
    check_warn "Vault check skipped (SKIP_VAULT=true)"
else
    if docker ps --filter name=nucleus-ads-api --format '{{.Names}}' | grep -q nucleus-ads-api; then
        CONTAINER_NAME=$(docker ps --filter name=nucleus-ads-api --format '{{.Names}}' | head -1)

        # Check for successful Vault authentication in logs
        if docker logs $CONTAINER_NAME 2>&1 | grep -q "Secrets loaded. Starting application"; then
            check_pass "Vault entrypoint completed successfully"

            # Check if secrets were fetched
            if docker logs $CONTAINER_NAME 2>&1 | grep -q "Exporting Google Ads credentials"; then
                check_pass "Google Ads credentials loaded from Vault"
            fi

            if docker logs $CONTAINER_NAME 2>&1 | grep -q "Exporting JWT keys"; then
                check_pass "JWT keys loaded from Vault"
            fi
        else
            # Check if it's stuck trying to authenticate
            if docker logs $CONTAINER_NAME 2>&1 | grep -q "Authenticating to Vault" && \
               ! docker logs $CONTAINER_NAME 2>&1 | grep -q "Secrets loaded"; then
                check_fail "Vault authentication in progress or failed"
                check_info "Check Vault connectivity and token"
            else
                check_warn "Unable to verify Vault entrypoint status"
            fi
        fi
    else
        check_fail "Container not running, cannot check Vault status"
    fi
fi

# Check 3: Redis Connectivity
check_start "Check 3: Redis Connectivity"

if command -v redis-cli &> /dev/null; then
    if redis-cli ping > /dev/null 2>&1; then
        check_pass "Redis is responding on host"

        # Check connection count
        CONN_COUNT=$(redis-cli INFO CLIENTS | grep connected_clients | cut -d: -f2 | tr -d '\r')
        check_info "Connected clients: $CONN_COUNT"
    else
        check_fail "Redis not responding on localhost:6379"
    fi
else
    check_warn "redis-cli not installed, cannot verify"
fi

# Check 4: API Health Endpoint (Direct)
check_start "Check 4: API Health Endpoint (Direct)"

HEALTH_RESPONSE=$(curl -sf http://localhost:8000/health 2>/dev/null || echo '{"status":"unreachable"}')
HEALTH_STATUS=$(echo "$HEALTH_RESPONSE" | jq -r '.status' 2>/dev/null || echo "unreachable")

if [[ "$HEALTH_STATUS" == "healthy" ]]; then
    check_pass "API health check passed (direct)"

    VERSION=$(echo "$HEALTH_RESPONSE" | jq -r '.version')
    check_info "Version: $VERSION"

    # Check components
    REDIS_OK=$(echo "$HEALTH_RESPONSE" | jq -r '.components.redis')
    SCHEDULER_OK=$(echo "$HEALTH_RESPONSE" | jq -r '.components.scheduler')

    if [[ "$REDIS_OK" == "true" ]]; then
        check_pass "Redis component healthy"
    else
        check_fail "Redis component unhealthy"
    fi

    if [[ "$SCHEDULER_OK" == "true" ]]; then
        check_pass "Scheduler component healthy"
    else
        check_fail "Scheduler component unhealthy"
    fi
else
    check_fail "API health check failed (status: $HEALTH_STATUS)"
fi

# Check 5: Nginx Proxy (if applicable)
check_start "Check 5: Nginx Reverse Proxy"

if command -v nginx &> /dev/null; then
    if systemctl is-active --quiet nginx; then
        check_pass "Nginx is running"

        # Test proxy with Host header
        PROXY_RESPONSE=$(curl -sf -H "Host: $DOMAIN" http://127.0.0.1/health 2>/dev/null || echo '{"status":"error"}')
        PROXY_STATUS=$(echo "$PROXY_RESPONSE" | jq -r '.status' 2>/dev/null || echo "error")

        if [[ "$PROXY_STATUS" == "healthy" ]]; then
            check_pass "Nginx proxy working (HTTP)"
            check_info "Proxying to backend successfully"
        else
            check_fail "Nginx proxy not working properly"
        fi
    else
        check_warn "Nginx installed but not running"
    fi
else
    check_warn "Nginx not installed"
fi

# Check 6: HTTPS/SSL (if not skipped)
check_start "Check 6: HTTPS/SSL Certificate"

if [[ "$SKIP_SSL" == "true" ]]; then
    check_warn "SSL check skipped (SKIP_SSL=true)"
else
    # Try HTTPS health check
    if curl -sfI $API_URL/health > /dev/null 2>&1; then
        check_pass "HTTPS endpoint reachable"

        # Get SSL certificate info
        if command -v openssl &> /dev/null; then
            CERT_INFO=$(echo | openssl s_client -servername $DOMAIN -connect $DOMAIN:443 2>/dev/null | \
                        openssl x509 -noout -dates 2>/dev/null)

            if [[ -n "$CERT_INFO" ]]; then
                EXPIRY=$(echo "$CERT_INFO" | grep notAfter | cut -d= -f2)
                check_pass "SSL certificate valid"
                check_info "Expires: $EXPIRY"

                # Check days until expiry
                EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s 2>/dev/null || echo 0)
                NOW_EPOCH=$(date +%s)
                DAYS_LEFT=$(( ($EXPIRY_EPOCH - $NOW_EPOCH) / 86400 ))

                if [[ $DAYS_LEFT -gt 30 ]]; then
                    check_pass "Certificate expires in $DAYS_LEFT days"
                elif [[ $DAYS_LEFT -gt 7 ]]; then
                    check_warn "Certificate expires in $DAYS_LEFT days (renewal recommended)"
                else
                    check_fail "Certificate expires in $DAYS_LEFT days (URGENT renewal needed)"
                fi
            fi
        fi
    else
        check_warn "HTTPS endpoint not reachable (may not be configured yet)"
        check_info "This is normal if SSL is not set up"
    fi
fi

# Check 7: Vault Status (if applicable)
check_start "Check 7: Vault Server Status"

if [[ "$SKIP_VAULT" == "true" ]]; then
    check_warn "Vault check skipped (SKIP_VAULT=true)"
elif [[ -z "$VAULT_ADDR" ]]; then
    check_warn "VAULT_ADDR not set, skipping Vault server check"
else
    if command -v vault &> /dev/null; then
        export VAULT_ADDR

        if vault status > /dev/null 2>&1; then
            VAULT_SEALED=$(vault status -format=json 2>/dev/null | jq -r '.sealed')

            if [[ "$VAULT_SEALED" == "false" ]]; then
                check_pass "Vault is unsealed and accessible"

                VAULT_VERSION=$(vault status -format=json 2>/dev/null | jq -r '.version')
                check_info "Version: $VAULT_VERSION"
            else
                check_fail "Vault is sealed (expected: unsealed)"
                check_info "Vault must be unsealed for application to fetch secrets"
            fi
        else
            check_fail "Cannot connect to Vault at $VAULT_ADDR"
        fi
    else
        check_warn "Vault CLI not installed, cannot verify server status"
    fi
fi

# Check 8: Environment Variables in Container
check_start "Check 8: Container Environment"

if docker ps --filter name=nucleus-ads-api --format '{{.Names}}' | grep -q nucleus-ads-api; then
    CONTAINER_NAME=$(docker ps --filter name=nucleus-ads-api --format '{{.Names}}' | head -1)

    # Check that sensitive vars are NOT exposed in env
    ENV_VARS=$(docker exec $CONTAINER_NAME env 2>/dev/null || echo "")

    # In production, Google Ads credentials should come from files, not env vars
    if echo "$ENV_VARS" | grep -q "GOOGLE_ADS_DEVELOPER_TOKEN=test"; then
        check_warn "Using test credentials (development mode)"
    elif echo "$ENV_VARS" | grep -q "GOOGLE_ADS_DEVELOPER_TOKEN="; then
        check_warn "Google Ads credentials in environment variables"
        check_info "Production should use Vault-injected files"
    else
        check_pass "Credentials not exposed in environment (good)"
    fi

    # Check JWT paths are set
    if docker exec $CONTAINER_NAME env | grep -q "JWT_JWKS_PRIVATE_PATH"; then
        check_pass "JWT key paths configured"
    else
        check_warn "JWT key paths not found in environment"
    fi
else
    check_fail "Container not running, cannot check environment"
fi

# Check 9: Docker Compose Configuration
check_start "Check 9: Docker Compose Setup"

if [[ -f docker-compose.production.yml ]]; then
    check_pass "docker-compose.production.yml exists"

    # Verify it's using production mode
    docker compose -f docker-compose.production.yml ps > /dev/null 2>&1
    check_pass "Docker Compose configuration valid"
else
    check_fail "docker-compose.production.yml not found"
fi

# Check 10: Log Quality
check_start "Check 10: Application Logs"

if docker ps --filter name=nucleus-ads-api --format '{{.Names}}' | grep -q nucleus-ads-api; then
    CONTAINER_NAME=$(docker ps --filter name=nucleus-ads-api --format '{{.Names}}' | head -1)

    # Check for errors in recent logs
    ERROR_COUNT=$(docker logs --tail 100 $CONTAINER_NAME 2>&1 | grep -c "ERROR" || echo "0")
    ERROR_COUNT=$(echo "$ERROR_COUNT" | tr -d '\n\r' | head -c 10)

    if [[ "$ERROR_COUNT" == "0" ]] || [[ $ERROR_COUNT -eq 0 ]] 2>/dev/null; then
        check_pass "No errors in recent logs"
    elif [[ $ERROR_COUNT -lt 5 ]]; then
        check_warn "Found $ERROR_COUNT errors in recent logs"
    else
        check_fail "Found $ERROR_COUNT errors in recent logs"
    fi

    # Check for startup confirmation
    if docker logs $CONTAINER_NAME 2>&1 | grep -q "Application startup complete"; then
        check_pass "Application started successfully"
    else
        check_warn "Application startup not confirmed in logs"
    fi
else
    check_fail "Container not running, cannot check logs"
fi

# Summary
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Verification Summary${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo "Total Checks: $CHECKS_TOTAL"
echo -e "${GREEN}Passed: $CHECKS_PASSED${NC}"
echo -e "${RED}Failed: $CHECKS_FAILED${NC}"
echo ""

if [[ $CHECKS_FAILED -eq 0 ]]; then
    echo -e "${GREEN}✓ All checks passed! Production deployment verified.${NC}"
    exit 0
elif [[ $CHECKS_FAILED -le 2 ]]; then
    echo -e "${YELLOW}⚠ Some checks failed, but deployment may be functional.${NC}"
    echo "Review failed checks above and address issues."
    exit 1
else
    echo -e "${RED}✗ Multiple checks failed. Production deployment has issues.${NC}"
    echo "Review failed checks and fix before proceeding."
    exit 2
fi
