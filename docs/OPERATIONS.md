# Operations Guide

Comprehensive operational procedures for the Nucleus Google Ads API.

## Table of Contents

1. [Monitoring](#monitoring)
2. [Secret Rotation](#secret-rotation)
3. [TLS Certificate Management](#tls-certificate-management)
4. [Backup Procedures](#backup-procedures)
5. [Incident Response](#incident-response)
6. [Scaling](#scaling)
7. [Maintenance](#maintenance)

---

## Monitoring

### Automated Monitoring

Use the monitoring script for real-time status:

```bash
# One-time check
./scripts/monitor.sh

# Continuous monitoring (refreshes every 5s)
WATCH_MODE=true ./scripts/monitor.sh

# Show recent logs
SHOW_LOGS=true ./scripts/monitor.sh
```

### Manual Health Checks

**API Health:**
```bash
curl http://localhost:8000/health
```

Expected response:
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

**Container Status:**
```bash
docker ps --filter name=nucleus-ads-api
docker stats nucleus-ads-api
docker logs -f nucleus-ads-api
```

**Redis Status:**
```bash
redis-cli ping  # Should return PONG
redis-cli INFO
redis-cli DBSIZE
```

**Nginx Status:**
```bash
sudo systemctl status nginx
sudo nginx -t
tail -f /var/log/nginx/nucleus-api-*.log
```

### Key Metrics to Monitor

| Metric | Warning Threshold | Critical Threshold | Action |
|--------|------------------|-------------------|--------|
| API Response Time | > 500ms | > 1000ms | Check logs, restart |
| Memory Usage | > 80% | > 90% | Investigate memory leak |
| Disk Space | > 80% | > 90% | Clean logs, expand disk |
| Redis Memory | > 6GB | > 7GB | Clear cache, check TTL |
| SSL Certificate | < 30 days | < 7 days | Renew certificate |
| Error Rate | > 1% | > 5% | Check logs, investigate |

### Log Locations

```bash
# Application logs
docker logs nucleus-ads-api

# Nginx access logs
/var/log/nginx/nucleus-api-access.log

# Nginx error logs
/var/log/nginx/nucleus-api-error.log

# Redis logs
/var/log/redis/redis-server.log
journalctl -u redis-server

# System logs
journalctl -xe
```

### Alerting (Recommended Setup)

Consider setting up automated alerts for:

- Container restarts
- API health check failures
- High error rates
- Resource exhaustion
- SSL certificate expiration

**Example cron job for monitoring:**
```bash
# Add to /etc/cron.d/nucleus-api-monitor
*/5 * * * * root /opt/nucleus-google-ads-framework/scripts/monitor.sh | grep -E "✗|⚠" && echo "Nucleus API: Issues detected" | mail -s "API Alert" admin@example.com
```

---

## Secret Rotation

### 1. Rotating Vault Token

**When to rotate:**
- Every 720 hours (default TTL)
- When token is compromised
- During security audits
- Before token expiration

**Procedure:**

```bash
# On Vault server/admin workstation
export VAULT_ADDR=https://vault.example.com:8200
export VAULT_TOKEN=your-admin-token

# Create new token
NEW_TOKEN=$(vault token create \
  -policy=nucleus-ads-api \
  -ttl=720h \
  -display-name="nucleus-ads-api-$(date +%Y%m%d)" \
  -format=json | jq -r '.auth.client_token')

# On VPS
echo "$NEW_TOKEN" | sudo tee /opt/secrets/vault-token
sudo chmod 600 /opt/secrets/vault-token
sudo chown 1000:1000 /opt/secrets/vault-token

# Restart container to pick up new token
cd /opt/nucleus-google-ads-framework
docker compose -f docker-compose.production.yml restart

# Verify
docker logs nucleus-ads-api | grep "Secrets loaded"

# Revoke old token (optional, after verifying new one works)
vault token revoke OLD_TOKEN_HERE
```

### 2. Rotating Google Ads Credentials

**When to rotate:**
- When credentials are compromised
- Every 90 days (security best practice)
- When team member with access leaves

**Procedure:**

```bash
# 1. Generate new OAuth2 credentials in Google Ads
# Visit: https://console.cloud.google.com/apis/credentials
# Generate new refresh token using OAuth2 playground

# 2. Update Vault
export VAULT_ADDR=https://vault.example.com:8200
export VAULT_TOKEN=your-admin-token

vault kv patch secret/nucleus-ads-api \
  google_ads_client_id="NEW_CLIENT_ID" \
  google_ads_client_secret="NEW_CLIENT_SECRET" \
  google_ads_refresh_token="NEW_REFRESH_TOKEN"

# 3. Restart application
cd /opt/nucleus-google-ads-framework
docker compose -f docker-compose.production.yml restart

# 4. Verify
docker logs nucleus-ads-api | grep "Google Ads"
curl http://localhost:8000/health

# 5. Test with actual API call
TOKEN=$(curl -s -X POST http://localhost:8000/dev/token \
  -H "Content-Type: application/json" \
  -d '{"user_id": "admin@example.com", "role": "admin"}' | jq -r '.token')

curl http://localhost:8000/api/search \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"query": "SELECT campaign.id FROM campaign LIMIT 1", "client_id": "YOUR_CLIENT_ID"}'
```

### 3. Rotating JWT Keys

**When to rotate:**
- Annually (preventive)
- When private key is compromised
- During security audits

**Procedure:**

```bash
# 1. Generate new RSA key pair
openssl genrsa -out /tmp/jwks-private-new.pem 2048
openssl rsa -in /tmp/jwks-private-new.pem -pubout -out /tmp/jwks-public-new.pem

# 2. Update Vault
JWT_PRIVATE_NEW=$(cat /tmp/jwks-private-new.pem)
JWT_PUBLIC_NEW=$(cat /tmp/jwks-public-new.pem)

vault kv patch secret/nucleus-ads-api \
  jwt_private_key="$JWT_PRIVATE_NEW" \
  jwt_public_key="$JWT_PUBLIC_NEW"

# 3. Clean up temporary files
shred -u /tmp/jwks-private-new.pem /tmp/jwks-public-new.pem

# 4. Restart application
docker compose -f docker-compose.production.yml restart

# 5. Verify new tokens work
curl -X POST http://localhost:8000/dev/token \
  -H "Content-Type: application/json" \
  -d '{"user_id": "test@example.com", "role": "viewer"}'

# NOTE: Old JWT tokens will immediately become invalid
# Coordinate with users or implement token migration period
```

---

## TLS Certificate Management

### Auto-Renewal (Certbot)

Certbot auto-renews certificates via systemd timer:

```bash
# Check auto-renewal status
sudo systemctl status certbot.timer

# Test renewal (dry run)
sudo certbot renew --dry-run

# Force renewal
sudo certbot renew --force-renewal

# Check certificate expiration
sudo certbot certificates
```

### Manual Renewal

```bash
# Renew specific domain
sudo certbot renew --cert-name example.com

# Reload Nginx to pick up new certificate
sudo systemctl reload nginx

# Verify new certificate
openssl s_client -connect example.com:443 -servername example.com < /dev/null 2>/dev/null | \
  openssl x509 -noout -dates
```

### Nginx Reload Hook

Ensure Nginx reloads after certificate renewal:

```bash
# Create renewal hook
sudo tee /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh > /dev/null <<'EOF'
#!/bin/bash
systemctl reload nginx
EOF

sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

# Test
sudo /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
```

### Certificate Expiration Monitoring

```bash
# Add to cron for weekly checks
cat > /etc/cron.weekly/check-ssl-expiry <<'EOF'
#!/bin/bash
DAYS_LEFT=$(echo | openssl s_client -servername example.com -connect example.com:443 2>/dev/null | \
  openssl x509 -noout -checkend 2592000)

if [ $? -ne 0 ]; then
  echo "SSL certificate for example.com expires in less than 30 days" | \
    mail -s "SSL Certificate Expiry Warning" admin@example.com
fi
EOF

chmod +x /etc/cron.weekly/check-ssl-expiry
```

---

## Backup Procedures

### Redis Backup

Redis is configured without persistence (in-memory cache only). No backups needed for cache data.

If you enable persistence:

```bash
# Manual save
redis-cli SAVE

# Background save
redis-cli BGSAVE

# Copy dump file
sudo cp /var/lib/redis/dump.rdb /backup/redis-$(date +%Y%m%d).rdb
```

### Application Configuration Backup

```bash
# Backup Vault secrets (encrypted)
export VAULT_ADDR=https://vault.example.com:8200
export VAULT_TOKEN=your-admin-token

vault kv get -format=json secret/nucleus-ads-api > \
  /backup/vault-secrets-$(date +%Y%m%d).json.enc

# Encrypt backup
openssl enc -aes-256-cbc -salt -in /backup/vault-secrets-*.json.enc \
  -out /backup/vault-secrets-encrypted-$(date +%Y%m%d).bin

# Remove unencrypted
shred -u /backup/vault-secrets-*.json.enc
```

### Docker Image Backup

```bash
# Save Docker image
docker save nucleus-ads-api:production | gzip > \
  /backup/nucleus-ads-api-$(date +%Y%m%d).tar.gz

# Upload to remote storage
aws s3 cp /backup/nucleus-ads-api-*.tar.gz s3://your-bucket/backups/
```

### Automated Backup Script

```bash
#!/bin/bash
# /etc/cron.daily/backup-nucleus-api

BACKUP_DIR="/backup/nucleus-api"
DATE=$(date +%Y%m%d)

mkdir -p $BACKUP_DIR

# Backup Docker image
docker save nucleus-ads-api:production | gzip > \
  $BACKUP_DIR/image-$DATE.tar.gz

# Backup configuration
cp -r /opt/nucleus-google-ads-framework/infra $BACKUP_DIR/config-$DATE/
cp /opt/nucleus-google-ads-framework/docker-compose.production.yml \
  $BACKUP_DIR/config-$DATE/

# Cleanup old backups (keep 7 days)
find $BACKUP_DIR -name "*.tar.gz" -mtime +7 -delete
find $BACKUP_DIR -name "config-*" -mtime +7 -exec rm -rf {} +
```

---

## Incident Response

### API Down

1. **Check container status:**
   ```bash
   docker ps -a | grep nucleus-ads-api
   docker logs --tail 100 nucleus-ads-api
   ```

2. **Check dependencies:**
   ```bash
   redis-cli ping
   curl -v $VAULT_ADDR/v1/sys/health
   ```

3. **Restart container:**
   ```bash
   docker compose -f docker-compose.production.yml restart
   ```

4. **If restart fails, check logs:**
   ```bash
   docker logs nucleus-ads-api 2>&1 | grep -E "ERROR|FATAL|Exception"
   ```

### High Memory Usage

1. **Identify source:**
   ```bash
   docker stats nucleus-ads-api
   redis-cli INFO MEMORY
   ```

2. **Clear Redis cache:**
   ```bash
   redis-cli FLUSHDB
   ```

3. **Restart application:**
   ```bash
   docker compose -f docker-compose.production.yml restart
   ```

### Quota Exceeded Errors

1. **Check quota status:**
   ```bash
   TOKEN=$(curl -s -X POST http://localhost:8000/dev/token \
     -H "Content-Type: application/json" \
     -d '{"user_id": "admin@example.com", "role": "admin"}' | jq -r '.token')

   curl http://localhost:8000/admin/quota/status \
     -H "Authorization: Bearer $TOKEN"
   ```

2. **Reset quota:**
   ```bash
   curl -X POST http://localhost:8000/admin/quota/reset \
     -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"global_daily": 1000000}'
   ```

### SSL Certificate Expired

1. **Renew immediately:**
   ```bash
   sudo certbot renew --force-renewal
   sudo systemctl reload nginx
   ```

2. **Verify:**
   ```bash
   curl -I https://example.com/health
   ```

---

## Scaling

### Vertical Scaling (More Resources)

**Increase Docker container resources:**

Edit `docker-compose.production.yml`:
```yaml
deploy:
  resources:
    limits:
      cpus: '12.0'  # Increase from 6.0
      memory: 32G   # Increase from 16G
    reservations:
      cpus: '8.0'   # Increase from 4.0
      memory: 16G   # Increase from 8G
```

Apply changes:
```bash
docker compose -f docker-compose.production.yml up -d --force-recreate
```

**Increase worker count:**

Edit `docker-compose.production.yml`:
```yaml
environment:
  SCHEDULER_WORKERS: 16  # Increase from 8
```

Or in Dockerfile:
```dockerfile
CMD ["uvicorn", "apps.api_server:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "12"]
```

### Horizontal Scaling (Load Balancing)

**Setup:**

1. Deploy multiple instances
2. Use Nginx load balancing
3. Share Redis across instances

**Nginx load balancer config:**
```nginx
upstream nucleus_api_cluster {
    least_conn;
    server 10.0.1.10:8000;
    server 10.0.1.11:8000;
    server 10.0.1.12:8000;
}

server {
    listen 443 ssl http2;
    server_name api.example.com;

    location / {
        proxy_pass http://nucleus_api_cluster;
        # ... proxy settings
    }
}
```

---

## Maintenance

### Regular Maintenance Tasks

**Daily:**
- Review error logs
- Check disk space
- Monitor API response times

**Weekly:**
- Review security logs
- Check SSL certificate expiration
- Update dependencies

**Monthly:**
- Review quota usage
- Audit user access
- Performance tuning
- Review and rotate secrets

**Quarterly:**
- Security audit
- Capacity planning
- Disaster recovery test
- Documentation review

### Updating the Application

```bash
# Pull latest code
cd /opt/nucleus-google-ads-framework
git fetch origin
git checkout <VERSION_TAG>

# Build new image
docker build -f Dockerfile.production -t nucleus-ads-api:production .

# Stop old container
docker compose -f docker-compose.production.yml down

# Start new container
docker compose -f docker-compose.production.yml up -d

# Verify
docker logs -f nucleus-ads-api
curl http://localhost:8000/health
```

### Rollback Procedure

```bash
# List previous images
docker images | grep nucleus-ads-api

# Tag previous version
docker tag OLD_IMAGE_ID nucleus-ads-api:production

# Restart with old version
docker compose -f docker-compose.production.yml up -d --force-recreate

# Verify
curl http://localhost:8000/health
```

### Log Rotation

**Nginx log rotation:**
```bash
# Already handled by logrotate
cat /etc/logrotate.d/nginx
```

**Docker log rotation:**

Edit `/etc/docker/daemon.json`:
```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
```

Restart Docker:
```bash
sudo systemctl restart docker
```

---

## Troubleshooting Quick Reference

| Issue | Command | Expected Output |
|-------|---------|----------------|
| Container not starting | `docker logs nucleus-ads-api` | Check for errors |
| API not responding | `curl localhost:8000/health` | `{"status": "healthy"}` |
| Redis down | `redis-cli ping` | `PONG` |
| Vault unreachable | `curl $VAULT_ADDR/v1/sys/health` | HTTP 200 |
| High CPU | `docker stats nucleus-ads-api` | < 80% |
| High memory | `docker stats nucleus-ads-api` | < 80% of limit |
| Nginx errors | `nginx -t` | `syntax is ok` |
| SSL issues | `certbot certificates` | Days until expiry |

---

## Support and Escalation

**For operational issues:**
1. Check this guide
2. Review application logs
3. Check monitoring dashboard
4. Contact on-call engineer

**For security incidents:**
1. Rotate compromised secrets immediately
2. Review access logs
3. Document incident
4. Contact security team

---

## Additional Resources

- [Deployment Guide](../PRODUCTION_DEPLOY.md)
- [Scripts README](../scripts/README.md)
- [API Documentation](http://localhost:8000/docs)
