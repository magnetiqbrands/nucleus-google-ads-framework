

# Deployment Guide - Nucleus Google Ads API

Comprehensive guide for containerized deployment with Docker, Docker Compose, Vault integration, and Nginx reverse proxy.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Container Build](#container-build)
- [Deployment Methods](#deployment-methods)
- [Vault Integration](#vault-integration)
- [Nginx Setup](#nginx-setup)
- [Monitoring & Logging](#monitoring--logging)
- [Operations](#operations)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

### Required Software
- Docker 20.10+
- Docker Compose 2.0+
- Git
- curl, jq (for scripts)

### Optional
- HashiCorp Vault (for secret management)
- Nginx (for reverse proxy)
- Let's Encrypt/Certbot (for SSL)

### VPS Requirements
- 8 vCPU / 32 GB RAM / 400 GB NVMe (recommended)
- Ubuntu 22.04 LTS or similar
- Root or sudo access

---

## Quick Start

### 1. Clone Repository

```bash
cd /opt
git clone https://github.com/magnetiqbrands/nucleus-google-ads-framework.git
cd nucleus-google-ads-framework
```

### 2. Build Image

```bash
# Build production image
docker build -t nucleus-ads-api:latest .

# Or use deployment script
chmod +x scripts/deploy.sh
./scripts/deploy.sh build
```

### 3. Configure Environment

```bash
# Copy environment example
cp .env.example .env

# Edit with your values
nano .env
```

### 4. Deploy with Docker Compose

```bash
# Start services
docker-compose up -d

# Check status
docker-compose ps

# View logs
docker-compose logs -f api
```

### 5. Verify Deployment

```bash
# Health check
curl http://localhost:8000/health

# API documentation
open http://localhost:8000/docs
```

---

## Container Build

### Multi-Stage Build

The Dockerfile uses a multi-stage build for optimization:

1. **base** - Base Python 3.11-slim with system dependencies
2. **dependencies** - Install Python packages
3. **test** - Run unit tests (optional CI stage)
4. **production** - Final slim image with app code

### Build Commands

```bash
# Build production image
docker build --target production -t nucleus-ads-api:latest .

# Build and run tests
docker build --target test -t nucleus-ads-api:test .

# Build with specific tag
docker build -t nucleus-ads-api:v1.0.0 .

# Build with build args
docker build \
  --build-arg BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ") \
  --build-arg VCS_REF=$(git rev-parse HEAD) \
  -t nucleus-ads-api:latest .
```

### Image Optimization

The production image is optimized for size and security:
- Non-root user (`adsapi`)
- Minimal base image (python:3.11-slim)
- Multi-stage build (only runtime dependencies)
- `.dockerignore` excludes unnecessary files
- Health check included

---

## Deployment Methods

### Method 1: Docker Compose (Recommended)

Best for single-server deployments.

```bash
# Start all services
docker-compose up -d

# Scale API workers (if needed)
docker-compose up -d --scale api=3

# Update deployment
docker-compose pull
docker-compose up -d --force-recreate

# Stop services
docker-compose down
```

### Method 2: Docker Run

For manual container management:

```bash
# Start Redis
docker run -d \
  --name nucleus-redis \
  --network nucleus-network \
  -p 127.0.0.1:6379:6379 \
  redis:7-alpine \
  redis-server --maxmemory 8gb --maxmemory-policy allkeys-lfu

# Start API
docker run -d \
  --name nucleus-ads-api \
  --network nucleus-network \
  -p 127.0.0.1:8000:8000 \
  -e REDIS_URL=redis://nucleus-redis:6379 \
  -e APP_ENV=production \
  -v ./secrets:/run/secrets:ro \
  nucleus-ads-api:latest
```

### Method 3: Deployment Script

Use the provided deployment script for automated workflows:

```bash
chmod +x scripts/deploy.sh

# Full deployment (test + build + push + deploy)
./scripts/deploy.sh full

# Just deploy
./scripts/deploy.sh deploy

# Build and push
./scripts/deploy.sh push

# Check health
./scripts/deploy.sh health

# View logs
./scripts/deploy.sh logs
```

#### Script Environment Variables

```bash
# Set registry
export REGISTRY="ghcr.io/magnetiqbrands"

# Set tag
export TAG="v1.0.0"

# Enable Vault
export USE_VAULT="true"

# Deploy
./scripts/deploy.sh deploy
```

---

## Vault Integration

### Overview

Vault integration provides secure secret management for:
- Google Ads API credentials
- JWT signing keys
- Database credentials
- Any other sensitive configuration

### Setup Vault Secrets

1. **Store secrets in Vault:**

```bash
# Login to Vault
vault login

# Write secrets
vault kv put secret/nucleus-ads-api \
  google_ads_developer_token="YOUR_DEV_TOKEN" \
  google_ads_client_id="YOUR_CLIENT_ID" \
  google_ads_client_secret="YOUR_CLIENT_SECRET" \
  google_ads_refresh_token="YOUR_REFRESH_TOKEN" \
  google_ads_login_customer_id="1234567890" \
  jwt_private_key="@/path/to/private-key.pem" \
  jwt_public_key="@/path/to/public-key.pem" \
  database_url="postgresql://user:pass@localhost:5432/db"
```

2. **Create Vault token or AppRole:**

```bash
# Option A: Create a token
vault token create -policy=nucleus-ads-api -ttl=720h > vault-token

# Option B: Create AppRole
vault write auth/approle/role/nucleus-ads-api \
  token_policies="nucleus-ads-api" \
  token_ttl=1h \
  token_max_ttl=4h

# Get Role ID
vault read auth/approle/role/nucleus-ads-api/role-id

# Generate Secret ID
vault write -f auth/approle/role/nucleus-ads-api/secret-id
```

3. **Configure Docker Compose:**

Create `.env` file:

```bash
VAULT_ADDR=https://vault.example.com:8200
VAULT_SECRET_PATH=secret/data/nucleus-ads-api
VAULT_TOKEN_FILE=./secrets/vault-token
```

4. **Deploy with Vault:**

```bash
# Create secrets directory
mkdir -p secrets
chmod 700 secrets

# Add Vault token
echo "YOUR_VAULT_TOKEN" > secrets/vault-token
chmod 600 secrets/vault-token

# Deploy
docker-compose -f docker-compose.yml -f docker-compose.vault.yml up -d

# Or use script
export USE_VAULT=true
./scripts/deploy.sh deploy
```

### Vault Authentication Methods

**Token Authentication (Simpler):**
```bash
# Mount token file
volumes:
  - ./secrets/vault-token:/run/secrets/vault-token:ro
```

**AppRole Authentication (More Secure):**
```bash
# Mount AppRole credentials
volumes:
  - ./secrets/vault-role-id:/run/secrets/vault-role-id:ro
  - ./secrets/vault-secret-id:/run/secrets/vault-secret-id:ro
```

### Secret Rotation

```bash
# Update secrets in Vault
vault kv put secret/nucleus-ads-api jwt_private_key="@/path/to/new-key.pem"

# Restart containers to fetch new secrets
docker-compose restart api
```

---

## Nginx Setup

### Install Nginx

```bash
sudo apt update
sudo apt install nginx certbot python3-certbot-nginx
```

### Configure Site

```bash
# Copy configuration
sudo cp infra/nginx.conf /etc/nginx/sites-available/nucleus-ads-api

# Edit domain name
sudo nano /etc/nginx/sites-available/nucleus-ads-api
# Replace api.example.com with your domain

# Enable site
sudo ln -s /etc/nginx/sites-available/nucleus-ads-api /etc/nginx/sites-enabled/

# Test configuration
sudo nginx -t

# Reload Nginx
sudo systemctl reload nginx
```

### SSL with Let's Encrypt

```bash
# Obtain certificate
sudo certbot --nginx -d api.example.com

# Auto-renewal is configured by certbot
# Verify renewal works:
sudo certbot renew --dry-run
```

### Nginx Operations

```bash
# Reload after config changes
sudo systemctl reload nginx

# Restart
sudo systemctl restart nginx

# Check status
sudo systemctl status nginx

# View logs
sudo tail -f /var/log/nginx/nucleus-ads-api-access.log
sudo tail -f /var/log/nginx/nucleus-ads-api-error.log
```

---

## Monitoring & Logging

### Container Logs

```bash
# Follow API logs
docker-compose logs -f api

# Follow Redis logs
docker-compose logs -f redis

# Last 100 lines
docker-compose logs --tail=100 api

# Export logs
docker-compose logs --no-color > deployment.log
```

### Application Logs

Logs are sent to stdout/stderr and collected by Docker:

```bash
# View with journald (if using systemd)
sudo journalctl -u docker -f

# Or direct container logs
docker logs -f nucleus-ads-api
```

### Health Monitoring

```bash
# Health endpoint
curl http://localhost:8000/health

# Readiness check
curl http://localhost:8000/health/ready

# System stats (requires admin token)
curl -H "Authorization: Bearer $TOKEN" \
  http://localhost:8000/admin/stats
```

### Redis Monitoring

```bash
# Enter Redis container
docker exec -it nucleus-redis redis-cli

# Check stats
INFO
INFO stats
INFO memory

# Monitor commands
MONITOR

# Check memory usage
MEMORY STATS
```

### Resource Monitoring

```bash
# Container stats
docker stats nucleus-ads-api nucleus-redis

# Detailed stats
docker inspect nucleus-ads-api | jq '.[0].State'
```

---

## Operations

### Update Deployment

```bash
# Pull latest code
git pull

# Build new image
docker build -t nucleus-ads-api:latest .

# Update containers
docker-compose up -d --force-recreate
```

### Rollback

```bash
# Using deployment script
export PREVIOUS_TAG=v1.0.0
./scripts/deploy.sh rollback

# Manual rollback
docker-compose down
docker tag nucleus-ads-api:v1.0.0 nucleus-ads-api:latest
docker-compose up -d
```

### Backup & Restore

**Backup:**
```bash
# Backup Redis data
docker exec nucleus-redis redis-cli SAVE
docker cp nucleus-redis:/data/dump.rdb ./backups/redis-$(date +%Y%m%d).rdb

# Backup secrets
tar -czf secrets-backup-$(date +%Y%m%d).tar.gz secrets/
```

**Restore:**
```bash
# Restore Redis
docker cp ./backups/redis-20250101.rdb nucleus-redis:/data/dump.rdb
docker-compose restart redis

# Restore secrets
tar -xzf secrets-backup-20250101.tar.gz
```

### Scaling

```bash
# Scale API containers (requires load balancer)
docker-compose up -d --scale api=4

# Adjust worker count
docker-compose exec api sh -c "pkill -HUP uvicorn"
```

---

## Troubleshooting

### Container Won't Start

```bash
# Check logs
docker-compose logs api

# Check events
docker events

# Inspect container
docker inspect nucleus-ads-api

# Check resource limits
docker stats
```

### Connection Issues

```bash
# Test Redis connection
docker exec nucleus-redis redis-cli PING

# Test API from container
docker exec nucleus-ads-api curl http://localhost:8000/health

# Check network
docker network inspect nucleus-network
```

### Performance Issues

```bash
# Check container resources
docker stats

# Check Redis memory
docker exec nucleus-redis redis-cli INFO memory

# Check API workers
docker exec nucleus-ads-api ps aux

# Check disk space
df -h
```

### Secret Loading Failures

```bash
# Check Vault connectivity
docker exec nucleus-ads-api curl -v $VAULT_ADDR/v1/sys/health

# Check secret permissions
ls -la secrets/

# Test Vault auth manually
docker exec -it nucleus-ads-api bash
/app/docker/vault-init.sh echo "Secrets loaded"
```

### Common Issues

**Issue: Port 8000 already in use**
```bash
# Find process
sudo lsof -i :8000
# Kill or change port in docker-compose.yml
```

**Issue: Out of disk space**
```bash
# Clean up Docker
docker system prune -a
docker volume prune
```

**Issue: Redis connection refused**
```bash
# Check Redis is running
docker ps | grep redis
# Check Redis logs
docker-compose logs redis
```

---

## Production Checklist

Before going to production:

- [ ] SSL certificates configured and auto-renewal enabled
- [ ] Vault secrets properly configured and tested
- [ ] JWT keys rotated and secured
- [ ] Firewall rules configured (ports 80, 443 only)
- [ ] Monitoring and alerting set up
- [ ] Log rotation configured
- [ ] Backup procedures documented and tested
- [ ] Resource limits appropriate for load
- [ ] Health checks passing
- [ ] Load testing completed (2k RPS target)
- [ ] Documentation updated
- [ ] Rollback procedure tested
- [ ] Team trained on operations

---

## Quick Reference

### Common Commands

```bash
# Deploy
./scripts/deploy.sh deploy

# Check health
curl http://localhost:8000/health

# View logs
docker-compose logs -f api

# Restart
docker-compose restart api

# Update
git pull && ./scripts/deploy.sh full

# Shell access
docker exec -it nucleus-ads-api bash
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `APP_ENV` | `development` | Environment (development/production) |
| `REDIS_URL` | `redis://redis:6379` | Redis connection URL |
| `GLOBAL_DAILY_QUOTA` | `1000000` | Global API quota |
| `SCHEDULER_WORKERS` | `8` | Number of scheduler workers |
| `LRU_CACHE_SIZE` | `10000` | LRU cache size |

---

For more information, see:
- [Setup Guide](SETUP.md)
- [Implementation Summary](IMPLEMENTATION_SUMMARY.md)
- [README](readme.md)
