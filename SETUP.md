# Nucleus Google Ads Framework - Setup Guide

Complete guide to setting up and running the Google Ads Multi-Client Automation API.

## Prerequisites

- Python 3.11 or higher
- Redis 6.0+ (8GB RAM allocated)
- PostgreSQL 13+ (optional, for state/logging)
- 8 vCPU / 32 GB RAM server (recommended)

## Quick Start (Development)

### 1. Clone and Install

```bash
cd /root/Claude/projects/nucleus-google-ads-framework

# Create virtual environment
python3 -m venv .venv
source .venv/bin/activate

# Install dependencies
make install-dev
```

### 2. Start Redis

```bash
# Using system Redis
sudo systemctl start redis

# Or using Docker
docker run -d -p 6379:6379 --name redis-ads redis:7-alpine
```

### 3. Configure Environment

```bash
# Copy example environment file
cp .env.example .env

# Edit .env with your configuration
# For development, defaults are usually fine
```

### 4. Run the Application

```bash
# Development mode (with auto-reload)
make run

# Or manually
uvicorn apps.api_server:app --reload --host 0.0.0.0 --port 8000
```

### 5. Access the API

- API: http://localhost:8000
- Swagger UI: http://localhost:8000/docs
- ReDoc: http://localhost:8000/redoc

## Testing

### Run Tests

```bash
# Run all tests
make test

# Run with coverage
make test-cov

# Run specific test file
pytest tests/test_cache.py -v
```

### Get a Development Token

The `/dev/token` endpoint creates JWT tokens for testing (disabled in production):

```bash
curl -X POST http://localhost:8000/dev/token \
  -H "Content-Type: application/json" \
  -d '{"user_id": "admin@example.com", "role": "admin"}'
```

Response:
```json
{
  "token": "eyJ...",
  "user_id": "admin@example.com",
  "role": "admin"
}
```

### Test API Endpoints

```bash
# Get health status
curl http://localhost:8000/health

# Search with JWT (replace TOKEN with actual token)
curl -X POST http://localhost:8000/api/search \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "query": "SELECT campaign.id, campaign.name FROM campaign",
    "client_id": "1234567890",
    "page_size": 100,
    "urgency": 50
  }'

# Get quota status (admin only)
curl -X GET http://localhost:8000/admin/quota/status \
  -H "Authorization: Bearer $TOKEN"

# Set client tier (admin only)
curl -X POST http://localhost:8000/admin/clients/1234567890/tier \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"tier": "gold"}'
```

## Production Deployment

### 1. System Setup

```bash
# Create dedicated user
sudo useradd -r -s /bin/false ads-api

# Create directories
sudo mkdir -p /opt/nucleus-google-ads-framework
sudo mkdir -p /etc/nucleus-ads-api
sudo mkdir -p /var/log/nucleus-ads-api

# Set ownership
sudo chown ads-api:ads-api /opt/nucleus-google-ads-framework
sudo chown ads-api:ads-api /var/log/nucleus-ads-api
```

### 2. Install Application

```bash
# Clone repository
cd /opt/nucleus-google-ads-framework
sudo -u ads-api git clone <repo-url> .

# Create virtual environment
sudo -u ads-api python3 -m venv .venv
sudo -u ads-api .venv/bin/pip install -U pip
sudo -u ads-api .venv/bin/pip install -e .
```

### 3. Configure Redis

```bash
# Copy Redis configuration
sudo cp infra/redis.conf /etc/redis/redis-ads.conf

# Edit as needed
sudo vim /etc/redis/redis-ads.conf

# Restart Redis
sudo systemctl restart redis
```

### 4. Setup PostgreSQL (Optional)

```bash
# Create database and user
sudo -u postgres psql

CREATE DATABASE google_ads;
CREATE USER ads_api_user WITH ENCRYPTED PASSWORD 'secure_password';
GRANT ALL PRIVILEGES ON DATABASE google_ads TO ads_api_user;
\q

# Load schema
psql -U ads_api_user -d google_ads -f infra/postgres.sql
```

### 5. Generate JWT Keys

```bash
# Generate RS256 key pair
openssl genrsa -out /etc/nucleus-ads-api/jwks-private.pem 2048
openssl rsa -in /etc/nucleus-ads-api/jwks-private.pem \
  -pubout -out /etc/nucleus-ads-api/jwks-public.pem

# Convert to JSON format (for JWKS)
# Or use the PEM files directly (app supports both)

sudo chown ads-api:ads-api /etc/nucleus-ads-api/jwks-*.pem
sudo chmod 600 /etc/nucleus-ads-api/jwks-private.pem
sudo chmod 644 /etc/nucleus-ads-api/jwks-public.pem
```

### 6. Create Environment File

```bash
sudo vim /etc/nucleus-ads-api/env
```

Contents:
```bash
APP_ENV=production
APP_HOST=0.0.0.0
APP_PORT=8000
APP_WORKERS=6
APP_LOG_LEVEL=INFO

REDIS_URL=redis://localhost:6379
DATABASE_URL=postgresql://ads_api_user:secure_password@localhost:5432/google_ads

JWT_JWKS_PUBLIC_PATH=/etc/nucleus-ads-api/jwks-public.pem
JWT_JWKS_PRIVATE_PATH=/etc/nucleus-ads-api/jwks-private.pem
API_JWT_AUDIENCE=ads-api
API_JWT_ISSUER=ads-auth
JWT_EXPIRY_MINUTES=15

GLOBAL_DAILY_QUOTA=1000000
LRU_CACHE_SIZE=10000
SCHEDULER_WORKERS=8

GOOGLE_ADS_YAML=/etc/google-ads/google-ads.yaml
```

### 7. Install Systemd Service

```bash
# Copy service file
sudo cp infra/ads-api.service /etc/systemd/system/

# Reload systemd
sudo systemctl daemon-reload

# Enable and start service
sudo systemctl enable ads-api
sudo systemctl start ads-api

# Check status
sudo systemctl status ads-api

# View logs
sudo journalctl -u ads-api -f
```

### 8. Setup Reverse Proxy (Nginx)

```bash
sudo vim /etc/nginx/sites-available/ads-api
```

Contents:
```nginx
upstream ads_api {
    server 127.0.0.1:8000;
    keepalive 64;
}

server {
    listen 80;
    server_name api.example.com;

    location / {
        proxy_pass http://ads_api;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
```

Enable and restart:
```bash
sudo ln -s /etc/nginx/sites-available/ads-api /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl restart nginx
```

## Monitoring

### Health Checks

```bash
# Application health
curl http://localhost:8000/health

# Readiness check (for load balancers)
curl http://localhost:8000/health/ready
```

### System Stats

```bash
# Get cache/scheduler/quota stats
curl -H "Authorization: Bearer $TOKEN" \
  http://localhost:8000/admin/stats
```

### Logs

```bash
# Application logs
sudo journalctl -u ads-api -f

# Redis logs
sudo tail -f /var/log/redis/redis-server.log

# Nginx logs
sudo tail -f /var/log/nginx/access.log
```

## Performance Tuning

### Redis

- Allocate 8GB RAM
- Use `allkeys-lfu` eviction policy
- Disable persistence (AOF/RDB) for pure cache use
- Enable lazy freeing

### Application

- Use 6-8 Uvicorn workers
- Enable uvloop for better async performance
- Set LRU cache to 10,000 entries
- Configure 8 scheduler workers

### PostgreSQL (if used)

- Set `shared_buffers` to 8GB
- Set `effective_cache_size` to 20GB
- Enable proper indexes on frequently queried columns

## Troubleshooting

### Application won't start

```bash
# Check logs
sudo journalctl -u ads-api -n 100

# Check if Redis is running
redis-cli ping

# Verify environment variables
sudo cat /etc/nucleus-ads-api/env
```

### High latency

```bash
# Check Redis connection
redis-cli --latency

# Check scheduler stats
curl -H "Authorization: Bearer $TOKEN" \
  http://localhost:8000/admin/stats | jq '.scheduler'

# Check quota status
curl -H "Authorization: Bearer $TOKEN" \
  http://localhost:8000/admin/quota/status
```

### Quota exhausted

```bash
# Reset global quota (admin only)
curl -X POST http://localhost:8000/admin/quota/reset \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"global_daily": 1000000}'

# Check client quota
curl -H "Authorization: Bearer $TOKEN" \
  http://localhost:8000/admin/clients/1234567890/status
```

## Architecture Summary

```
┌─────────────────────────────────────────────────┐
│               FastAPI Application               │
│  ┌──────────┐  ┌──────────┐  ┌──────────────┐  │
│  │   Auth   │  │   API    │  │    Admin     │  │
│  │  (JWT)   │  │ Endpoints│  │  Endpoints   │  │
│  └──────────┘  └──────────┘  └──────────────┘  │
└──────────┬──────────┬──────────┬────────────────┘
           │          │          │
    ┌──────▼──────────▼──────────▼──────┐
    │     Google Ads Manager            │
    │  (GAQL/Mutate + Retry Logic)      │
    └──────┬──────────┬──────────┬───────┘
           │          │          │
   ┌───────▼────┐ ┌──▼─────┐ ┌──▼──────────┐
   │   Cache    │ │ Quota  │ │  Scheduler  │
   │ (LRU+Redis)│ │Governor│ │  (Priority) │
   └────────────┘ └────────┘ └─────────────┘
           │          │          │
    ┌──────▼──────────▼──────────▼──────┐
    │           Redis (8GB)              │
    └────────────────────────────────────┘
```

## Next Steps

1. **Implement Real Google Ads Client**: Replace mock client with actual Google Ads SDK integration
2. **Add PostgreSQL Integration**: Implement logging and state persistence
3. **Setup Monitoring**: Add Prometheus metrics and Grafana dashboards
4. **CI/CD Pipeline**: Automate testing and deployment
5. **Load Testing**: Validate performance under 2k RPS
6. **Security Hardening**: Implement key rotation, audit trails, etc.

## Support

For issues and questions, check:
- Documentation: `readme.md`, `Google Ads Automation — Codex Quickstart.md`
- Logs: `sudo journalctl -u ads-api`
- Health endpoint: `http://localhost:8000/health`
