# Deployment Scripts

Automation scripts for deploying the Nucleus Google Ads API.

## Scripts Overview

### 🚀 Production Deployment

#### `deploy-production.sh`
**Complete automated production deployment**

One-command deployment that handles everything:
- Installs Docker
- Sets up Redis on host
- Clones repository
- Configures Vault token
- Builds and deploys application
- Sets up Nginx with SSL

**Usage:**
```bash
sudo VAULT_ADDR=https://vault.example.com:8200 \
     DOMAIN=api.example.com \
     EMAIL=admin@example.com \
     ./deploy-production.sh
```

**Environment Variables:**
- `VAULT_ADDR` (required) - Vault server address
- `VAULT_SECRET_PATH` (optional) - Path to secrets (default: `secret/data/nucleus-ads-api`)
- `DOMAIN` (required for Nginx) - Your domain name
- `EMAIL` (optional) - Email for Let's Encrypt
- `SETUP_REDIS` (optional) - Install Redis (default: `yes`)
- `SETUP_NGINX` (optional) - Install Nginx (default: `yes`)

---

### 🔐 Vault Setup

#### `setup-vault-secrets.sh`
**Initialize Vault with Google Ads credentials and JWT keys**

Interactive script that:
- Prompts for Google Ads API credentials
- Generates RSA key pair for JWT
- Stores all secrets in Vault
- Creates Vault policy
- Generates application token

**Usage:**
```bash
export VAULT_ADDR=https://vault.example.com:8200
export VAULT_TOKEN=your-root-or-admin-token
./setup-vault-secrets.sh
```

**What it creates:**
- Vault secret at `secret/nucleus-ads-api` containing:
  - Google Ads credentials
  - JWT public/private keys
- Vault policy `nucleus-ads-api`
- Application token with 720h TTL

**After running:**
```bash
# Copy the application token to your VPS
sudo mkdir -p /opt/secrets
echo 'GENERATED_TOKEN' | sudo tee /opt/secrets/vault-token
sudo chmod 600 /opt/secrets/vault-token
sudo chown 1000:1000 /opt/secrets/vault-token
```

---

### 🌐 Nginx Setup

#### `setup-nginx.sh`
**Configure Nginx reverse proxy with SSL**

Automated Nginx configuration:
- Installs Nginx and Certbot
- Creates reverse proxy config
- Obtains SSL certificate from Let's Encrypt
- Sets up HTTPS redirect
- Configures security headers

**Usage:**
```bash
sudo DOMAIN=api.example.com \
     EMAIL=admin@example.com \
     ./setup-nginx.sh
```

**Prerequisites:**
- Application running on localhost:8000
- DNS pointing to server
- Ports 80 and 443 open in firewall

**What it creates:**
- Nginx config: `/etc/nginx/sites-available/nucleus-ads-api`
- SSL certificate: `/etc/letsencrypt/live/DOMAIN/`
- Logs: `/var/log/nginx/nucleus-ads-api-*.log`

---

### 🛠️ Development Deployment

#### `deploy.sh`
**Legacy deployment script with multiple modes**

**Usage:**
```bash
./deploy.sh [COMMAND]
```

**Commands:**
- `build` - Build Docker image
- `test` - Run tests in container
- `push` - Push image to registry
- `deploy` - Deploy to server
- `full` - Build, test, and deploy
- `rollback` - Rollback to previous version
- `logs` - View application logs
- `health` - Check health endpoint

---

## Quick Start Guides

### First-Time Production Deployment

1. **Setup Vault secrets** (run from your workstation):
   ```bash
   export VAULT_ADDR=https://vault.example.com:8200
   export VAULT_TOKEN=your-admin-token
   ./scripts/setup-vault-secrets.sh
   ```

2. **Deploy to VPS** (run on VPS as root):
   ```bash
   sudo VAULT_ADDR=https://vault.example.com:8200 \
        DOMAIN=api.example.com \
        EMAIL=admin@example.com \
        /path/to/deploy-production.sh
   ```

3. **Test deployment**:
   ```bash
   curl https://api.example.com/health
   ```

### Manual Step-by-Step Deployment

If you prefer manual control:

1. **Setup Redis**:
   ```bash
   sudo apt install redis-server
   redis-cli ping  # Should return PONG
   ```

2. **Clone repository**:
   ```bash
   cd /opt
   git clone https://github.com/magnetiqbrands/nucleus-google-ads-framework.git
   cd nucleus-google-ads-framework
   ```

3. **Setup Vault token**:
   ```bash
   sudo mkdir -p /opt/secrets
   echo 'YOUR_TOKEN' | sudo tee /opt/secrets/vault-token
   sudo chmod 600 /opt/secrets/vault-token
   sudo chown 1000:1000 /opt/secrets/vault-token
   ```

4. **Deploy application**:
   ```bash
   export VAULT_ADDR=https://vault.example.com:8200
   export VAULT_SECRET_PATH=secret/data/nucleus-ads-api
   docker compose -f docker-compose.production.yml up -d
   ```

5. **Setup Nginx**:
   ```bash
   sudo DOMAIN=api.example.com EMAIL=admin@example.com \
        ./scripts/setup-nginx.sh
   ```

### Development Deployment

For local development without Vault:

```bash
docker compose -f docker-compose.development.yml up -d
curl http://localhost:8000/health
```

---

## Troubleshooting

### Vault token permission denied
```bash
sudo chown 1000:1000 /opt/secrets/vault-token
sudo chmod 600 /opt/secrets/vault-token
```

### Container won't start
```bash
# Check logs
docker logs nucleus-ads-api

# Verify Vault connectivity
docker exec nucleus-ads-api curl -v $VAULT_ADDR/v1/sys/health
```

### SSL certificate issues
```bash
# Renew certificate
sudo certbot renew

# Check certificate
sudo certbot certificates
```

### Redis connection failed
```bash
# Check Redis status
sudo systemctl status redis-server

# Test connection
redis-cli ping
```

---

## Environment Variables Reference

### Production Deployment

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `VAULT_ADDR` | Yes | - | Vault server address |
| `VAULT_SECRET_PATH` | No | `secret/data/nucleus-ads-api` | Path to secrets in Vault |
| `DOMAIN` | Yes* | - | Domain name (*required if SETUP_NGINX=yes) |
| `EMAIL` | No | `admin@$DOMAIN` | Email for Let's Encrypt |
| `SETUP_REDIS` | No | `yes` | Install and configure Redis |
| `SETUP_NGINX` | No | `yes` | Install and configure Nginx |

### Application Runtime

| Variable | Default | Description |
|----------|---------|-------------|
| `APP_ENV` | `production` | Environment (production/development) |
| `APP_HOST` | `0.0.0.0` | Host to bind |
| `APP_PORT` | `8000` | Port to listen on |
| `APP_LOG_LEVEL` | `INFO` | Logging level |
| `REDIS_URL` | `redis://127.0.0.1:6379` | Redis connection URL |
| `LRU_CACHE_SIZE` | `10000` | In-memory cache size |
| `GLOBAL_DAILY_QUOTA` | `1000000` | Daily API quota |
| `SCHEDULER_WORKERS` | `8` | Number of scheduler workers |
| `JWT_EXPIRY_MINUTES` | `15` | JWT token expiry time |

---

## Security Checklist

Before production deployment:

- [ ] Vault token secured with chmod 600
- [ ] Vault token owned by uid 1000
- [ ] Redis bound to 127.0.0.1 only
- [ ] Firewall allows only ports 80, 443
- [ ] SSL certificate installed
- [ ] Certbot auto-renewal enabled
- [ ] Strong Google Ads credentials stored in Vault
- [ ] JWT keys generated with 2048-bit RSA
- [ ] Application runs as non-root user (adsapi)

---

## Support

For detailed deployment guide, see:
- [PRODUCTION_DEPLOY.md](../PRODUCTION_DEPLOY.md) - Quick start guide
- [DEPLOYMENT.md](../DEPLOYMENT.md) - Comprehensive deployment guide
