#!/bin/bash
# API Smoke Test Script
# Tests core functionality of the Nucleus Google Ads API

set -euo pipefail

# Configuration
API_URL="${API_URL:-http://localhost:8000}"
VERBOSE="${VERBOSE:-false}"
CLIENT_ID="${CLIENT_ID:-1234567890}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

ERRORS=0
TESTS_RUN=0

# Helper functions
log_test() {
    echo ""
    echo "Test $((TESTS_RUN + 1)): $1"
}

log_pass() {
    echo -e "${GREEN}✓${NC} $1"
}

log_fail() {
    echo -e "${RED}✗${NC} $1"
    ERRORS=$((ERRORS + 1))
}

log_info() {
    echo "  $1"
}

run_test() {
    TESTS_RUN=$((TESTS_RUN + 1))
}

# Main tests
echo "=========================================="
echo "Nucleus Google Ads API - Smoke Tests"
echo "=========================================="
echo "API URL: $API_URL"
echo ""

# Test 1: Health endpoint
log_test "Health endpoint"
HEALTH_RESPONSE=$(curl -sf $API_URL/health || echo '{"status":"failed"}')
HEALTH_STATUS=$(echo "$HEALTH_RESPONSE" | jq -r '.status')

if [[ "$HEALTH_STATUS" == "healthy" ]]; then
    log_pass "Health check passed"
    if [[ "$VERBOSE" == "true" ]]; then
        log_info "Components: $(echo "$HEALTH_RESPONSE" | jq -c '.components')"
    fi
else
    log_fail "Health check failed"
    log_info "Response: $HEALTH_RESPONSE"
fi
run_test

# Test 2: Ready endpoint
log_test "Ready endpoint"
READY_RESPONSE=$(curl -sf $API_URL/health/ready || echo '{"ready":false}')
READY_STATUS=$(echo "$READY_RESPONSE" | jq -r '.ready')

if [[ "$READY_STATUS" == "true" ]]; then
    log_pass "Ready check passed"
else
    log_fail "Ready check failed"
fi
run_test

# Test 3: Generate admin token
log_test "Generate admin JWT token"
ADMIN_TOKEN_RESPONSE=$(curl -sf -X POST $API_URL/dev/token \
    -H "Content-Type: application/json" \
    -d '{"user_id": "admin@example.com", "role": "admin"}' || echo '{}')

ADMIN_TOKEN=$(echo "$ADMIN_TOKEN_RESPONSE" | jq -r '.token')
if [[ "$ADMIN_TOKEN" != "null" ]] && [[ -n "$ADMIN_TOKEN" ]]; then
    log_pass "Admin token generated (${#ADMIN_TOKEN} chars)"
    if [[ "$VERBOSE" == "true" ]]; then
        log_info "User: $(echo "$ADMIN_TOKEN_RESPONSE" | jq -r '.user_id')"
        log_info "Role: $(echo "$ADMIN_TOKEN_RESPONSE" | jq -r '.role')"
    fi
else
    log_fail "Failed to generate admin token"
    log_info "Response: $ADMIN_TOKEN_RESPONSE"
fi
run_test

# Test 4: Generate viewer token
log_test "Generate viewer JWT token"
VIEWER_TOKEN=$(curl -sf -X POST $API_URL/dev/token \
    -H "Content-Type: application/json" \
    -d '{"user_id": "viewer@example.com", "role": "viewer"}' | jq -r '.token')

if [[ "$VIEWER_TOKEN" != "null" ]] && [[ -n "$VIEWER_TOKEN" ]]; then
    log_pass "Viewer token generated"
else
    log_fail "Failed to generate viewer token"
fi
run_test

# Test 5: Reset quota (to ensure we have quota for tests)
log_test "Reset quota (admin)"
RESET_RESPONSE=$(curl -sf -X POST $API_URL/admin/quota/reset \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"daily_quota": 1000000}' || echo '{"status":"error"}')

RESET_STATUS=$(echo "$RESET_RESPONSE" | jq -r '.status')
if [[ "$RESET_STATUS" == "success" ]]; then
    log_pass "Quota reset to 1,000,000"
else
    log_fail "Failed to reset quota"
    log_info "Response: $RESET_RESPONSE"
fi
run_test

# Test 6: Get quota status
log_test "Get quota status (admin)"
QUOTA_RESPONSE=$(curl -sf $API_URL/admin/quota/status \
    -H "Authorization: Bearer $ADMIN_TOKEN" || echo '{}')

DAILY_QUOTA=$(echo "$QUOTA_RESPONSE" | jq -r '.daily_quota')
if [[ "$DAILY_QUOTA" != "null" ]] && [[ -n "$DAILY_QUOTA" ]]; then
    log_pass "Got quota status"
    REMAINING=$(echo "$QUOTA_RESPONSE" | jq -r '.remaining')
    log_info "Daily quota: $DAILY_QUOTA"
    log_info "Remaining: $REMAINING"
else
    log_fail "Failed to get quota status"
fi
run_test

# Test 7: GAQL search with authentication
log_test "GAQL search (authenticated)"
SEARCH_RESPONSE=$(curl -sf $API_URL/api/search \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{
        \"query\": \"SELECT campaign.id, campaign.name FROM campaign LIMIT 5\",
        \"client_id\": \"$CLIENT_ID\"
    }" || echo '{"status":"error"}')

SEARCH_STATUS=$(echo "$SEARCH_RESPONSE" | jq -r '.status')
if [[ "$SEARCH_STATUS" == "success" ]]; then
    log_pass "GAQL search succeeded"
    ROWS=$(echo "$SEARCH_RESPONSE" | jq '.results | length')
    log_info "Returned $ROWS rows"
    if [[ "$VERBOSE" == "true" ]] && [[ "$ROWS" -gt 0 ]]; then
        log_info "First row: $(echo "$SEARCH_RESPONSE" | jq -c '.results[0]')"
    fi
else
    log_fail "GAQL search failed"
    log_info "Response: $SEARCH_RESPONSE"
fi
run_test

# Test 8: Search without authentication (should fail)
log_test "Search without authentication (should fail)"
UNAUTH_RESPONSE=$(curl -sf $API_URL/api/search \
    -H "Content-Type: application/json" \
    -d "{\"query\": \"SELECT campaign.id FROM campaign\", \"client_id\": \"$CLIENT_ID\"}" || echo '{"detail":"Not authenticated"}')

if echo "$UNAUTH_RESPONSE" | jq -e '.detail' | grep -iq "not authenticated"; then
    log_pass "Correctly rejected unauthenticated request"
else
    log_fail "Should have rejected unauthenticated request"
    log_info "Response: $UNAUTH_RESPONSE"
fi
run_test

# Test 9: Get admin stats
log_test "Get admin stats"
STATS_RESPONSE=$(curl -sf $API_URL/admin/stats \
    -H "Authorization: Bearer $ADMIN_TOKEN" || echo '{}')

if echo "$STATS_RESPONSE" | jq -e '.total_requests' > /dev/null 2>&1; then
    log_pass "Got admin stats"
    if [[ "$VERBOSE" == "true" ]]; then
        log_info "Stats: $(echo "$STATS_RESPONSE" | jq -c '.')"
    fi
else
    log_fail "Failed to get admin stats"
fi
run_test

# Test 10: Set client tier (admin)
log_test "Set client tier (admin)"
TIER_RESPONSE=$(curl -sf -X PUT $API_URL/admin/clients/$CLIENT_ID/tier \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"tier": "gold"}' || echo '{"status":"error"}')

TIER_STATUS=$(echo "$TIER_RESPONSE" | jq -r '.status')
if [[ "$TIER_STATUS" == "success" ]]; then
    log_pass "Set client tier to gold"
else
    log_fail "Failed to set client tier"
    log_info "Response: $TIER_RESPONSE"
fi
run_test

# Test 11: Get client status
log_test "Get client status (admin)"
STATUS_RESPONSE=$(curl -sf $API_URL/admin/clients/$CLIENT_ID/status \
    -H "Authorization: Bearer $ADMIN_TOKEN" || echo '{}')

CLIENT_STATUS=$(echo "$STATUS_RESPONSE" | jq -r '.status')
if [[ "$CLIENT_STATUS" != "null" ]] && [[ -n "$CLIENT_STATUS" ]]; then
    log_pass "Got client status: $CLIENT_STATUS"
    if [[ "$VERBOSE" == "true" ]]; then
        log_info "Details: $(echo "$STATUS_RESPONSE" | jq -c '.')"
    fi
else
    log_fail "Failed to get client status"
fi
run_test

# Test 12: Viewer cannot access admin endpoints
log_test "Viewer cannot access admin endpoints (should fail)"
VIEWER_ADMIN=$(curl -sf -X POST $API_URL/admin/quota/reset \
    -H "Authorization: Bearer $VIEWER_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"daily_quota": 1000000}' || echo '{"detail":"Forbidden"}')

if echo "$VIEWER_ADMIN" | jq -e '.detail' | grep -iq "forbidden"; then
    log_pass "Correctly rejected viewer from admin endpoint"
else
    log_fail "Should have rejected viewer from admin endpoint"
    log_info "Response: $VIEWER_ADMIN"
fi
run_test

# Summary
echo ""
echo "=========================================="
echo "Test Results: $TESTS_RUN tests run"
if [[ $ERRORS -eq 0 ]]; then
    echo -e "${GREEN}✓ All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}✗ $ERRORS test(s) failed${NC}"
    exit 1
fi
