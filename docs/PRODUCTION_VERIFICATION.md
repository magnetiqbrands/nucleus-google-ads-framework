# Production Deployment Verification

Quick reference for verifying production deployments of the Nucleus Google Ads API.

## Quick Verification

Run the automated verification script:

```bash
cd /opt/nucleus-google-ads-framework
./scripts/verify-production.sh
```

For deployments without Vault (development):
```bash
SKIP_VAULT=true SKIP_SSL=true ./scripts/verify-production.sh
```

---

## Manual Verification Steps

### 1. Health Endpoint Through Proxy

**Test with Host header (simulating domain):**
```bash
curl -H "Host: your-domain.com" http://127.0.0.1/health
```

**Expected response:**
```json
{
  "status": "healthy",
  "version": "0.1.0",
  "components": {
    "redis": true,
    "scheduler": true
  }
}
```

**With HTTPS (production):**
```bash
curl -I https://your-domain.com/health
```

**Expected headers:**
```
HTTP/1.1 200 OK
Server: nginx/1.24.0 (Ubuntu)
Content-Type: application/json
```

---

### 2. Docker Container Status

**Check running containers:**
```bash
docker compose -f docker-compose.production.yml ps
```

**Expected output:**
```
NAME              IMAGE                        STATUS
nucleus-ads-api   nucleus-ads-api:production   Up X minutes (healthy)
```

**Key indicators:**
- ✅ **Status:** `Up` (not `Restarting` or `Exited`)
- ✅ **Health:** `healthy` (if healthcheck configured)
- ✅ **Uptime:** Stable (not constantly restarting)

**Check container logs:**
```bash
docker logs nucleus-ads-api | tail -50
```

**Expected log entries:**
```
==> Authenticating to Vault...
==> Fetching secrets from secret/data/nucleus-ads-api...
==> Exporting Google Ads credentials...
==> Exporting JWT keys...
==> Secrets loaded. Starting application...
==> Starting application...
INFO: Connected to Redis: redis://127.0.0.1:6379
INFO: QuotaGovernor initialized
INFO: PriorityScheduler initialized with 8 workers
INFO: GoogleAdsManager initialized
INFO: JWT configuration initialized
INFO: Application startup complete
INFO: Uvicorn running on http://0.0.0.0:8000
```

---

### 3. Vault Status Verification

**On Vault server or with Vault CLI:**

```bash
export VAULT_ADDR=https://vault.example.com:8200
vault status
```

**Expected output:**
```
Key             Value
---             -----
Seal Type       shamir
Initialized     true
Sealed          false    ← CRITICAL: Must be "false"
Total Shares    5
Threshold       3
Version         1.15.0
Storage Type    raft
Cluster Name    vault-cluster
HA Enabled      true
```

**Critical check:**
- ✅ **Sealed: false** - Vault must be unsealed for app to fetch secrets
- ❌ **Sealed: true** - Application will fail to start

**Verify secrets are accessible:**
```bash
export VAULT_TOKEN=your-app-token
vault kv get secret/nucleus-ads-api
```

**Expected to see:**
- `google_ads_developer_token`
- `google_ads_client_id`
- `google_ads_client_secret`
- `google_ads_refresh_token`
- `google_ads_login_customer_id`
- `jwt_private_key`
- `jwt_public_key`

---

### 4. Redis Connectivity

**From host:**
```bash
redis-cli ping
```

**Expected:**
```
PONG
```

**Check connection count:**
```bash
redis-cli INFO CLIENTS | grep connected_clients
```

**Expected:**
```
connected_clients:8    ← API workers connected
```

**From within container:**
```bash
docker exec nucleus-ads-api sh -c 'python3 -c "import redis; r = redis.from_url(\"redis://127.0.0.1:6379\"); print(r.ping())"'
```

**Expected:**
```
True
```

---

### 5. Vault Entrypoint Completion

**Check container logs for successful Vault authentication:**

```bash
docker logs nucleus-ads-api 2>&1 | grep -E "Authenticating|Fetching|Exporting|Secrets loaded"
```

**Success indicators:**
```
==> Authenticating to Vault...          ✓
==> Fetching secrets from...            ✓
==> Exporting Google Ads credentials... ✓
==> Exporting JWT keys...               ✓
==> Secrets loaded. Starting...         ✓
```

**Failure indicators:**
```
==> Authenticating to Vault...
==> Authenticating to Vault...
==> Authenticating to Vault...
(repeating - stuck in retry loop)
```

**Common issues:**
- Vault unreachable (network/DNS)
- Invalid token
- Token expired
- Vault sealed
- Secret path incorrect

---

### 6. Environment Variable Security

**Check that secrets are NOT exposed in environment:**

```bash
docker exec nucleus-ads-api env | grep -E "GOOGLE_ADS|JWT_JWKS"
```

**Production (secure):**
```
JWT_JWKS_PRIVATE_PATH=/run/secrets/jwks-private.pem
JWT_JWKS_PUBLIC_PATH=/run/secrets/jwks-public.pem
```
*Note: No actual credentials in env vars*

**Development (test credentials):**
```
GOOGLE_ADS_DEVELOPER_TOKEN=test-dev-token
GOOGLE_ADS_USE_MOCK=true
```
*Note: Test credentials are acceptable in development*

---

### 7. SSL/TLS Certificate

**Check certificate expiration:**
```bash
echo | openssl s_client -servername your-domain.com -connect your-domain.com:443 2>/dev/null | \
  openssl x509 -noout -dates
```

**Expected:**
```
notBefore=Oct  1 00:00:00 2025 GMT
notAfter=Dec 30 23:59:59 2025 GMT
```

**Check days until expiry:**
```bash
certbot certificates
```

**Expected:**
```
Certificate Name: your-domain.com
  Expiry Date: 2025-12-30 23:59:59+00:00 (90 days)
  Certificate Path: /etc/letsencrypt/live/your-domain.com/fullchain.pem
```

**Warning thresholds:**
- ✅ **> 30 days:** Good
- ⚠️ **7-30 days:** Plan renewal
- ❌ **< 7 days:** URGENT renewal needed

---

### 8. Nginx Status

**Check Nginx is running:**
```bash
systemctl status nginx
```

**Expected:**
```
● nginx.service - A high performance web server
   Active: active (running)
```

**Test configuration:**
```bash
nginx -t
```

**Expected:**
```
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
```

**Check site is enabled:**
```bash
ls -la /etc/nginx/sites-enabled/ | grep nucleus
```

**Expected:**
```
lrwxrwxrwx ... nucleus-ads-api -> /etc/nginx/sites-available/nucleus-ads-api
```

---

### 9. API Functional Tests

**Generate admin token:**
```bash
TOKEN=$(curl -s -X POST https://your-domain.com/dev/token \
  -H "Content-Type: application/json" \
  -d '{"user_id": "admin@example.com", "role": "admin"}' | jq -r '.token')

echo $TOKEN
```

**Test GAQL search:**
```bash
curl https://your-domain.com/api/search \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "query": "SELECT campaign.id, campaign.name FROM campaign LIMIT 5",
    "client_id": "1234567890"
  }' | jq .
```

**Expected response:**
```json
{
  "status": "success",
  "results": [...]
}
```

**Test quota status:**
```bash
curl https://your-domain.com/admin/quota/status \
  -H "Authorization: Bearer $TOKEN" | jq .
```

---

### 10. Resource Usage

**Container resource usage:**
```bash
docker stats nucleus-ads-api --no-stream
```

**Expected ranges:**
```
CPU: 1-5%    (idle), 10-50% (under load)
MEM: 200-500 MB (depends on workers)
```

**Redis memory:**
```bash
redis-cli INFO MEMORY | grep used_memory_human
```

**Expected:**
```
used_memory_human:1-2M (cache data)
```

**Disk space:**
```bash
df -h /
```

**Expected:**
```
/ ... 20% (< 80% is healthy)
```

---

## Verification Checklist

Use this checklist after deployment:

### Container
- [ ] Container is running (`docker ps`)
- [ ] Container status is `Up` and `healthy`
- [ ] No restart loops (stable uptime)
- [ ] Logs show "Application startup complete"

### Vault Integration (Production Only)
- [ ] Vault server is unsealed (`vault status`)
- [ ] Vault token is valid and accessible
- [ ] Logs show "Secrets loaded. Starting application"
- [ ] Google Ads credentials loaded
- [ ] JWT keys loaded

### Connectivity
- [ ] Redis responds to ping (`redis-cli ping`)
- [ ] API health endpoint returns 200
- [ ] Components show as healthy in health response

### Proxy & SSL
- [ ] Nginx is running and configured
- [ ] HTTP proxy works with Host header
- [ ] HTTPS endpoint accessible
- [ ] SSL certificate valid and > 30 days to expiry

### Security
- [ ] Credentials not exposed in environment variables
- [ ] JWT keys stored in files, not env vars
- [ ] Container runs as non-root user (uid 1000)
- [ ] File permissions correct on vault-token (600, uid 1000)

### Functionality
- [ ] Can generate JWT tokens
- [ ] Can execute GAQL queries
- [ ] RBAC enforced (viewer denied admin access)
- [ ] Quota management works

---

## Troubleshooting

### Container keeps restarting

**Check:**
```bash
docker logs nucleus-ads-api
```

**Common causes:**
- Vault unreachable → Check `VAULT_ADDR` and network
- Invalid Vault token → Check `/opt/secrets/vault-token`
- Redis unavailable → Check `redis-cli ping`
- Port conflict → Check if port 8000 is in use

### Vault authentication fails

**Check:**
```bash
# Verify token file exists
ls -la /opt/secrets/vault-token

# Verify permissions
# Should be: -rw------- 1 ubuntu ubuntu (or uid 1000)

# Fix if needed
sudo chown 1000:1000 /opt/secrets/vault-token
sudo chmod 600 /opt/secrets/vault-token

# Test Vault connectivity from container
docker exec nucleus-ads-api curl -v $VAULT_ADDR/v1/sys/health
```

### Health endpoint returns 503

**Possible causes:**
- Redis not connected
- Scheduler not initialized
- Application still starting

**Check logs:**
```bash
docker logs nucleus-ads-api | grep -E "ERROR|Exception"
```

### Nginx 502 Bad Gateway

**Causes:**
- Backend API not running
- Upstream configuration wrong
- Port mismatch

**Check:**
```bash
# Verify API is running
curl http://localhost:8000/health

# Check Nginx error log
tail -f /var/log/nginx/nucleus-api-error.log
```

---

## Automated Verification

**Run full verification:**
```bash
./scripts/verify-production.sh
```

**With custom domain:**
```bash
DOMAIN=api.example.com ./scripts/verify-production.sh
```

**Skip Vault checks (development):**
```bash
SKIP_VAULT=true ./scripts/verify-production.sh
```

**Skip SSL checks (local testing):**
```bash
SKIP_SSL=true ./scripts/verify-production.sh
```

---

## Expected Results Summary

| Check | Expected Status | Critical? |
|-------|----------------|-----------|
| Container running | ✓ Up & healthy | Yes |
| Vault unsealed | ✓ Sealed: false | Yes (production) |
| Vault entrypoint | ✓ Secrets loaded | Yes (production) |
| Redis connectivity | ✓ PONG | Yes |
| Health endpoint | ✓ 200 OK | Yes |
| Nginx proxy | ✓ 200 OK | Yes (production) |
| HTTPS/SSL | ✓ Valid cert | Yes (production) |
| No errors in logs | ✓ 0 errors | Yes |
| JWT tokens work | ✓ Generated | Yes |
| API functional | ✓ Queries work | Yes |

---

## Support

For deployment issues:
- Review [Operations Guide](./OPERATIONS.md)
- Check [Production Deploy Guide](../PRODUCTION_DEPLOY.md)
- Run monitoring script: `./scripts/monitor.sh`
- Review container logs: `docker logs nucleus-ads-api`
