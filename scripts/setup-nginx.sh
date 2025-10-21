#!/bin/bash
# Nginx Setup Script for Nucleus Google Ads API
# Configures Nginx reverse proxy with SSL via Certbot

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-}"
SITE_NAME="nucleus-ads-api"
NGINX_CONFIG_DIR="/etc/nginx/sites-available"
NGINX_ENABLED_DIR="/etc/nginx/sites-enabled"

echo -e "${GREEN}==> Nucleus Google Ads API - Nginx Setup${NC}"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}ERROR: This script must be run as root${NC}"
   echo "Usage: sudo DOMAIN=your-domain.com EMAIL=you@example.com ./setup-nginx.sh"
   exit 1
fi

# Validate inputs
if [[ -z "$DOMAIN" ]]; then
    echo -e "${RED}ERROR: DOMAIN environment variable is required${NC}"
    echo "Usage: sudo DOMAIN=your-domain.com EMAIL=you@example.com ./setup-nginx.sh"
    exit 1
fi

if [[ -z "$EMAIL" ]]; then
    echo -e "${YELLOW}WARNING: EMAIL not set, using admin@${DOMAIN}${NC}"
    EMAIL="admin@${DOMAIN}"
fi

echo "Domain: $DOMAIN"
echo "Email: $EMAIL"
echo ""

# Install Nginx and Certbot
echo -e "${GREEN}==> Installing Nginx and Certbot...${NC}"
apt-get update
apt-get install -y nginx certbot python3-certbot-nginx

# Check if API is running
echo -e "${GREEN}==> Checking if API is running...${NC}"
if ! curl -sf http://localhost:8000/health > /dev/null 2>&1; then
    echo -e "${YELLOW}WARNING: API not responding on localhost:8000${NC}"
    echo "Please ensure the API container is running before continuing"
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Create Nginx config from template
echo -e "${GREEN}==> Creating Nginx configuration...${NC}"

cat > "$NGINX_CONFIG_DIR/$SITE_NAME" <<EOF
# Nucleus Google Ads API - Nginx Configuration
# Site: $DOMAIN -> 127.0.0.1:8000

# Upstream
upstream nucleus_api {
    server 127.0.0.1:8000;
    keepalive 32;
}

# HTTP -> HTTPS redirect
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN www.$DOMAIN;

    # Certbot ACME challenge
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    # Redirect to HTTPS
    location / {
        return 301 https://$DOMAIN\$request_uri;
    }
}

# HTTPS server
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN www.$DOMAIN;

    # SSL certificates (will be added by Certbot)
    # ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    # ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    # include /etc/letsencrypt/options-ssl-nginx.conf;
    # ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;

    # Logging
    access_log /var/log/nginx/${SITE_NAME}-access.log;
    error_log /var/log/nginx/${SITE_NAME}-error.log;

    # Proxy settings
    location / {
        proxy_pass http://nucleus_api;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Connection "";

        # Timeouts
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }

    # Health check (no auth)
    location /health {
        proxy_pass http://nucleus_api;
        access_log off;
    }
}
EOF

echo -e "${GREEN}✓ Created Nginx config at $NGINX_CONFIG_DIR/$SITE_NAME${NC}"

# Enable site
echo -e "${GREEN}==> Enabling site...${NC}"
ln -sf "$NGINX_CONFIG_DIR/$SITE_NAME" "$NGINX_ENABLED_DIR/$SITE_NAME"

# Test configuration
echo -e "${GREEN}==> Testing Nginx configuration...${NC}"
if ! nginx -t; then
    echo -e "${RED}ERROR: Nginx configuration test failed${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Nginx configuration is valid${NC}"

# Reload Nginx
echo -e "${GREEN}==> Reloading Nginx...${NC}"
systemctl reload nginx
systemctl enable nginx

echo -e "${GREEN}✓ Nginx reloaded${NC}"

# Obtain SSL certificate
echo -e "${GREEN}==> Obtaining SSL certificate...${NC}"
echo "This will request a certificate from Let's Encrypt"
echo ""

# Create webroot directory for ACME challenge
mkdir -p /var/www/certbot

# Run Certbot
if certbot --nginx -d "$DOMAIN" -d "www.$DOMAIN" --email "$EMAIL" --agree-tos --no-eff-email --redirect; then
    echo -e "${GREEN}✓ SSL certificate obtained and installed${NC}"
else
    echo -e "${RED}ERROR: Failed to obtain SSL certificate${NC}"
    echo "You may need to:"
    echo "1. Ensure DNS is pointing to this server"
    echo "2. Check firewall allows ports 80 and 443"
    echo "3. Verify domain ownership"
    exit 1
fi

# Test HTTPS
echo -e "${GREEN}==> Testing HTTPS endpoint...${NC}"
sleep 2
if curl -sf "https://$DOMAIN/health" > /dev/null 2>&1; then
    echo -e "${GREEN}✓ HTTPS endpoint is working${NC}"
else
    echo -e "${YELLOW}WARNING: HTTPS endpoint test failed${NC}"
    echo "Manual verification required: curl https://$DOMAIN/health"
fi

# Display summary
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Nginx Setup Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Site: https://$DOMAIN"
echo "Health: https://$DOMAIN/health"
echo "Config: $NGINX_CONFIG_DIR/$SITE_NAME"
echo "Logs: /var/log/nginx/${SITE_NAME}-*.log"
echo ""
echo "Certificate auto-renewal is configured via Certbot"
echo "To renew manually: sudo certbot renew"
echo ""
echo "Test your API:"
echo "  curl https://$DOMAIN/health"
echo ""
