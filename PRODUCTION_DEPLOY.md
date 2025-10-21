# Production Deployment - Quick Start

Simplified production deployment using Vault, host Redis, and Nginx.

## Prerequisites

- VPS with Docker installed
- Redis running on host at 127.0.0.1:6379
- Vault accessible with valid token
- Domain pointing to server (example.com)

## 1. Setup Vault Secrets

Store secrets in Vault:

```bash
vault kv put secret/nucleus-ads-api \
  google_ads_developer_token="YOUR_TOKEN" \
  google_ads_client_id="YOUR_CLIENT_ID" \
  google_ads_client_secret="YOUR_CLIENT_SECRET" \
  google_ads_refresh_token="YOUR_REFRESH_TOKEN" \
  google_ads_login_customer_id="1234567890" \
  jwt_private_key="@/path/to/private-key.pem" \
  jwt_public_key="@/path/to/public-key.pem"
```

Create Vault token and store on server:

```bash
# On Vault server
vault token create -policy=nucleus-ads-api -ttl=720h

# On VPS
sudo mkdir -p /opt/secrets
echo "YOUR_VAULT_TOKEN" | sudo tee /opt/secrets/vault-token
sudo chmod 600 /opt/secrets/vault-token
```

## 2. Start Redis on Host

```bash
# Install Redis
sudo apt install redis-server

# Configure Redis
sudo tee /etc/redis/redis.conf <<EOF
bind 127.0.0.1
port 6379
maxmemory 8gb
maxmemory-policy allkeys-lfu
save ""
appendonly no
EOF

# Start Redis
sudo systemctl enable redis-server
sudo systemctl start redis-server

# Verify
redis-cli ping  # Should return PONG
```

## 3. Deploy Application

```bash
# Clone repository
cd /opt
git clone https://github.com/magnetiqbrands/nucleus-google-ads-framework.git
cd nucleus-google-ads-framework

# Set environment
export VAULT_ADDR=https://vault.example.com:8200
export VAULT_SECRET_PATH=secret/data/nucleus-ads-api

# Build and start
docker-compose -f docker-compose.production.yml up -d

# Check logs
docker logs -f nucleus-ads-api

# Verify health
curl http://localhost:8000/health
```

## 4. Configure Nginx

```bash
# Install Nginx
sudo apt install nginx certbot python3-certbot-nginx

# Copy config
sudo cp infra/nginx-production.conf /etc/nginx/sites-available/nucleus-api

# Edit domain (replace example.com with your domain)
sudo nano /etc/nginx/sites-available/nucleus-api

# Enable site
sudo ln -s /etc/nginx/sites-available/nucleus-api /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx

# Get SSL certificate
sudo certbot --nginx -d example.com -d www.example.com

# Verify HTTPS
curl https://example.com/health
```

## 5. Verify Deployment

```bash
# Test health endpoint
curl https://example.com/health

# Get dev token
curl -X POST https://example.com/dev/token \
  -H "Content-Type: application/json" \
  -d '{"user_id": "admin@example.com", "role": "admin"}'

# Test API
curl https://example.com/api/search \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "query": "SELECT campaign.id FROM campaign LIMIT 10",
    "client_id": "1234567890"
  }'
```

## Operations

### Update Deployment

```bash
cd /opt/nucleus-google-ads-framework
git pull
docker-compose -f docker-compose.production.yml build
docker-compose -f docker-compose.production.yml up -d --force-recreate
```

### View Logs

```bash
docker logs -f nucleus-ads-api
tail -f /var/log/nginx/nucleus-api-access.log
```

### Restart Services

```bash
# Restart API
docker-compose -f docker-compose.production.yml restart

# Restart Nginx
sudo systemctl reload nginx

# Restart Redis
sudo systemctl restart redis-server
```

### Monitor Resources

```bash
# Container stats
docker stats nucleus-ads-api

# Redis stats
redis-cli INFO

# System resources
htop
df -h
```

## Troubleshooting

### Container won't start

```bash
# Check logs
docker logs nucleus-ads-api

# Check Vault connectivity
docker exec nucleus-ads-api curl -v $VAULT_ADDR/v1/sys/health

# Verify token
sudo cat /opt/secrets/vault-token
```

### Can't connect to Redis

```bash
# Check Redis is running
sudo systemctl status redis-server

# Test connection
redis-cli ping

# Check Redis logs
sudo journalctl -u redis-server -f
```

### SSL certificate issues

```bash
# Renew certificate
sudo certbot renew

# Check certificate
sudo certbot certificates

# Test SSL
curl -vI https://example.com
```

## Production Checklist

- [ ] Vault token secured at `/opt/secrets/vault-token` (chmod 600)
- [ ] Redis running on 127.0.0.1:6379
- [ ] SSL certificate installed and auto-renewal configured
- [ ] Firewall allows ports 80, 443 only
- [ ] Health endpoint returns 200
- [ ] Nginx logs rotating
- [ ] Backup procedures documented
- [ ] Monitoring configured

## File Summary

**Production files:**
- `Dockerfile.production` - Minimal production build
- `docker/vault-entrypoint.sh` - Vault secret bootstrap
- `docker-compose.production.yml` - Production compose (host network)
- `infra/nginx-production.conf` - Nginx reverse proxy

**Commands:**
```bash
# Build
docker build -f Dockerfile.production -t nucleus-ads-api:production .

# Run
docker-compose -f docker-compose.production.yml up -d

# Logs
docker logs -f nucleus-ads-api

# Health
curl http://localhost:8000/health
```
