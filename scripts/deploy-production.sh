#!/bin/bash
# Complete Production Deployment Script for Nucleus Google Ads API
# Automates full production deployment on VPS

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
VAULT_ADDR="${VAULT_ADDR:-}"
VAULT_SECRET_PATH="${VAULT_SECRET_PATH:-secret/data/nucleus-ads-api}"
DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-}"
SETUP_REDIS="${SETUP_REDIS:-yes}"
SETUP_NGINX="${SETUP_NGINX:-yes}"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Nucleus Google Ads API${NC}"
echo -e "${BLUE}Production Deployment${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}ERROR: This script must be run as root${NC}"
   echo "Usage: sudo VAULT_ADDR=... DOMAIN=... ./deploy-production.sh"
   exit 1
fi

# Validate required variables
MISSING_VARS=()

if [[ -z "$VAULT_ADDR" ]]; then
    MISSING_VARS+=("VAULT_ADDR")
fi

if [[ "$SETUP_NGINX" == "yes" ]] && [[ -z "$DOMAIN" ]]; then
    MISSING_VARS+=("DOMAIN")
fi

if [[ ${#MISSING_VARS[@]} -gt 0 ]]; then
    echo -e "${RED}ERROR: Required environment variables not set:${NC}"
    for var in "${MISSING_VARS[@]}"; do
        echo "  - $var"
    done
    echo ""
    echo "Usage:"
    echo "  sudo VAULT_ADDR=https://vault.example.com:8200 \\"
    echo "       DOMAIN=api.example.com \\"
    echo "       EMAIL=admin@example.com \\"
    echo "       ./deploy-production.sh"
    exit 1
fi

echo -e "${GREEN}Configuration:${NC}"
echo "  Vault Address: $VAULT_ADDR"
echo "  Secret Path: $VAULT_SECRET_PATH"
echo "  Domain: ${DOMAIN:-N/A}"
echo "  Email: ${EMAIL:-N/A}"
echo "  Setup Redis: $SETUP_REDIS"
echo "  Setup Nginx: $SETUP_NGINX"
echo ""

read -p "Continue with deployment? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Deployment cancelled"
    exit 0
fi

# Step 1: Install Docker
echo ""
echo -e "${GREEN}==> Step 1: Installing Docker...${NC}"

if command -v docker &> /dev/null; then
    echo -e "${YELLOW}Docker already installed${NC}"
    docker --version
else
    echo "Installing Docker..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    systemctl enable docker
    systemctl start docker
    echo -e "${GREEN}✓ Docker installed${NC}"
fi

# Step 2: Setup Redis
if [[ "$SETUP_REDIS" == "yes" ]]; then
    echo ""
    echo -e "${GREEN}==> Step 2: Setting up Redis...${NC}"

    if command -v redis-cli &> /dev/null && redis-cli ping > /dev/null 2>&1; then
        echo -e "${YELLOW}Redis already running${NC}"
    else
        apt-get update
        apt-get install -y redis-server

        # Configure Redis
        cat > /etc/redis/redis.conf <<EOF
bind 127.0.0.1
port 6379
maxmemory 8gb
maxmemory-policy allkeys-lfu
save ""
appendonly no
EOF

        systemctl enable redis-server
        systemctl restart redis-server

        # Test
        if redis-cli ping > /dev/null 2>&1; then
            echo -e "${GREEN}✓ Redis installed and running${NC}"
        else
            echo -e "${RED}ERROR: Redis installation failed${NC}"
            exit 1
        fi
    fi
else
    echo ""
    echo -e "${YELLOW}==> Step 2: Skipping Redis setup${NC}"
fi

# Step 3: Clone repository
echo ""
echo -e "${GREEN}==> Step 3: Cloning repository...${NC}"

REPO_DIR="/opt/nucleus-google-ads-framework"

if [[ -d "$REPO_DIR" ]]; then
    echo "Repository already exists, pulling latest..."
    cd "$REPO_DIR"
    git pull
else
    echo "Cloning repository..."
    cd /opt
    git clone https://github.com/magnetiqbrands/nucleus-google-ads-framework.git
    cd "$REPO_DIR"
fi

echo -e "${GREEN}✓ Repository ready at $REPO_DIR${NC}"

# Step 4: Setup Vault token
echo ""
echo -e "${GREEN}==> Step 4: Setting up Vault token...${NC}"

if [[ ! -f /opt/secrets/vault-token ]]; then
    echo -e "${YELLOW}Vault token not found at /opt/secrets/vault-token${NC}"
    echo ""
    echo "Please provide the Vault token for this application."
    echo "You can generate one using: scripts/setup-vault-secrets.sh"
    echo ""
    read -sp "Vault Token: " VAULT_TOKEN
    echo ""

    mkdir -p /opt/secrets
    echo "$VAULT_TOKEN" > /opt/secrets/vault-token
    chmod 600 /opt/secrets/vault-token
    chown 1000:1000 /opt/secrets/vault-token

    echo -e "${GREEN}✓ Vault token saved${NC}"
else
    echo -e "${YELLOW}Vault token already exists${NC}"
    # Fix permissions
    chmod 600 /opt/secrets/vault-token
    chown 1000:1000 /opt/secrets/vault-token
fi

# Step 5: Build and deploy
echo ""
echo -e "${GREEN}==> Step 5: Building and deploying application...${NC}"

export VAULT_ADDR
export VAULT_SECRET_PATH

# Build image
docker build -f Dockerfile.production -t nucleus-ads-api:production .

# Deploy with docker-compose
docker compose -f docker-compose.production.yml up -d

# Wait for startup
echo "Waiting for application to start..."
sleep 10

# Check health
if curl -sf http://localhost:8000/health > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Application is healthy${NC}"
    curl -s http://localhost:8000/health | jq .
else
    echo -e "${RED}ERROR: Application health check failed${NC}"
    echo "Check logs: docker logs nucleus-ads-api"
    exit 1
fi

# Step 6: Setup Nginx
if [[ "$SETUP_NGINX" == "yes" ]]; then
    echo ""
    echo -e "${GREEN}==> Step 6: Setting up Nginx and SSL...${NC}"

    export DOMAIN
    export EMAIL

    bash "$REPO_DIR/scripts/setup-nginx.sh"
else
    echo ""
    echo -e "${YELLOW}==> Step 6: Skipping Nginx setup${NC}"
fi

# Display summary
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Deployment Complete!${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "${GREEN}Application Status:${NC}"
echo "  Container: nucleus-ads-api"
echo "  Status: $(docker ps --filter name=nucleus-ads-api --format '{{.Status}}')"
echo "  Health: http://localhost:8000/health"

if [[ "$SETUP_NGINX" == "yes" ]]; then
    echo ""
    echo -e "${GREEN}Public Endpoints:${NC}"
    echo "  Health: https://$DOMAIN/health"
    echo "  API: https://$DOMAIN/api/"
fi

echo ""
echo -e "${GREEN}Management Commands:${NC}"
echo "  View logs:    docker logs -f nucleus-ads-api"
echo "  Restart:      docker compose -f $REPO_DIR/docker-compose.production.yml restart"
echo "  Stop:         docker compose -f $REPO_DIR/docker-compose.production.yml down"
echo "  Update:       cd $REPO_DIR && git pull && docker compose -f docker-compose.production.yml up -d --build"
echo ""
echo -e "${GREEN}Monitoring:${NC}"
echo "  Container stats: docker stats nucleus-ads-api"
echo "  Redis stats:     redis-cli INFO"
echo "  Nginx logs:      tail -f /var/log/nginx/nucleus-ads-api-*.log"
echo ""

if [[ "$SETUP_NGINX" == "yes" ]]; then
    echo "Test your API:"
    echo "  # Get dev token"
    echo "  TOKEN=\$(curl -s -X POST https://$DOMAIN/dev/token \\"
    echo "    -H 'Content-Type: application/json' \\"
    echo "    -d '{\"user_id\": \"admin@example.com\", \"role\": \"admin\"}' | jq -r .token)"
    echo ""
    echo "  # Test search"
    echo "  curl https://$DOMAIN/api/search \\"
    echo "    -H \"Authorization: Bearer \$TOKEN\" \\"
    echo "    -H 'Content-Type: application/json' \\"
    echo "    -d '{\"query\": \"SELECT campaign.id FROM campaign LIMIT 5\", \"client_id\": \"1234567890\"}'"
else
    echo "To setup Nginx later, run:"
    echo "  sudo DOMAIN=your-domain.com EMAIL=you@example.com ./scripts/setup-nginx.sh"
fi

echo ""
echo -e "${GREEN}Deployment successful! 🎉${NC}"
echo ""
