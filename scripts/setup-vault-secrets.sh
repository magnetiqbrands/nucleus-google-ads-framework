#!/bin/bash
# Vault Secrets Setup Script for Nucleus Google Ads API
# Initializes Vault with Google Ads credentials and JWT keys

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
VAULT_ADDR="${VAULT_ADDR:-https://vault.example.com:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
SECRET_PATH="${VAULT_SECRET_PATH:-secret/nucleus-ads-api}"
POLICY_NAME="nucleus-ads-api"
TOKEN_TTL="${TOKEN_TTL:-720h}"

echo -e "${GREEN}==> Nucleus Google Ads API - Vault Setup${NC}"
echo ""
echo "Vault Address: $VAULT_ADDR"
echo "Secret Path: $SECRET_PATH"
echo ""

# Check if vault CLI is installed
if ! command -v vault &> /dev/null; then
    echo -e "${RED}ERROR: Vault CLI not found${NC}"
    echo "Install Vault CLI from: https://www.vaultproject.io/downloads"
    exit 1
fi

# Check Vault token
if [[ -z "$VAULT_TOKEN" ]]; then
    echo -e "${YELLOW}VAULT_TOKEN not set, attempting to use existing auth...${NC}"
fi

# Export Vault address
export VAULT_ADDR

# Test Vault connectivity
echo -e "${GREEN}==> Testing Vault connectivity...${NC}"
if ! vault status > /dev/null 2>&1; then
    echo -e "${RED}ERROR: Cannot connect to Vault at $VAULT_ADDR${NC}"
    echo "Ensure:"
    echo "  1. Vault server is running"
    echo "  2. VAULT_ADDR is correct"
    echo "  3. Network connectivity exists"
    exit 1
fi

echo -e "${GREEN}✓ Connected to Vault${NC}"

# Prompt for Google Ads credentials
echo ""
echo -e "${GREEN}==> Google Ads Credentials${NC}"
echo "Enter your Google Ads API credentials:"
echo ""

read -p "Developer Token: " GOOGLE_ADS_DEVELOPER_TOKEN
read -p "Client ID: " GOOGLE_ADS_CLIENT_ID
read -sp "Client Secret: " GOOGLE_ADS_CLIENT_SECRET
echo ""
read -sp "Refresh Token: " GOOGLE_ADS_REFRESH_TOKEN
echo ""
read -p "Login Customer ID (MCC): " GOOGLE_ADS_LOGIN_CUSTOMER_ID
echo ""

# Generate JWT keys
echo -e "${GREEN}==> Generating JWT RSA key pair...${NC}"

TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Generate private key
openssl genrsa -out "$TEMP_DIR/jwks-private.pem" 2048 2>/dev/null

# Extract public key
openssl rsa -in "$TEMP_DIR/jwks-private.pem" -pubout -out "$TEMP_DIR/jwks-public.pem" 2>/dev/null

echo -e "${GREEN}✓ JWT keys generated${NC}"

# Read keys
JWT_PRIVATE_KEY=$(cat "$TEMP_DIR/jwks-private.pem")
JWT_PUBLIC_KEY=$(cat "$TEMP_DIR/jwks-public.pem")

# Store secrets in Vault
echo -e "${GREEN}==> Storing secrets in Vault...${NC}"

vault kv put "$SECRET_PATH" \
  google_ads_developer_token="$GOOGLE_ADS_DEVELOPER_TOKEN" \
  google_ads_client_id="$GOOGLE_ADS_CLIENT_ID" \
  google_ads_client_secret="$GOOGLE_ADS_CLIENT_SECRET" \
  google_ads_refresh_token="$GOOGLE_ADS_REFRESH_TOKEN" \
  google_ads_login_customer_id="$GOOGLE_ADS_LOGIN_CUSTOMER_ID" \
  jwt_private_key="$JWT_PRIVATE_KEY" \
  jwt_public_key="$JWT_PUBLIC_KEY"

echo -e "${GREEN}✓ Secrets stored at $SECRET_PATH${NC}"

# Create Vault policy
echo -e "${GREEN}==> Creating Vault policy...${NC}"

vault policy write "$POLICY_NAME" - <<EOF
# Policy for Nucleus Google Ads API

# Read secrets
path "$SECRET_PATH" {
  capabilities = ["read"]
}

path "secret/data/$POLICY_NAME" {
  capabilities = ["read"]
}
EOF

echo -e "${GREEN}✓ Policy '$POLICY_NAME' created${NC}"

# Create token for the application
echo -e "${GREEN}==> Creating application token...${NC}"

APP_TOKEN=$(vault token create \
  -policy="$POLICY_NAME" \
  -ttl="$TOKEN_TTL" \
  -display-name="nucleus-ads-api" \
  -format=json | jq -r '.auth.client_token')

echo -e "${GREEN}✓ Application token created (TTL: $TOKEN_TTL)${NC}"

# Display summary
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Vault Setup Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Secret Path: $SECRET_PATH"
echo "Policy: $POLICY_NAME"
echo "Token TTL: $TOKEN_TTL"
echo ""
echo -e "${YELLOW}Application Token (save this securely):${NC}"
echo "$APP_TOKEN"
echo ""
echo "On your VPS, run:"
echo "  sudo mkdir -p /opt/secrets"
echo "  echo '$APP_TOKEN' | sudo tee /opt/secrets/vault-token"
echo "  sudo chmod 600 /opt/secrets/vault-token"
echo "  sudo chown 1000:1000 /opt/secrets/vault-token"
echo ""
echo "To verify secrets:"
echo "  export VAULT_TOKEN='$APP_TOKEN'"
echo "  vault kv get $SECRET_PATH"
echo ""

# Optionally save token to file
read -p "Save token to file? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    TOKEN_FILE="${TOKEN_FILE:-vault-token.txt}"
    echo "$APP_TOKEN" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    echo -e "${GREEN}✓ Token saved to $TOKEN_FILE${NC}"
    echo -e "${YELLOW}WARNING: Keep this file secure and delete after use!${NC}"
fi

echo ""
echo "Next steps:"
echo "  1. Deploy the token to your VPS (see commands above)"
echo "  2. Set environment variables:"
echo "     export VAULT_ADDR=$VAULT_ADDR"
echo "     export VAULT_SECRET_PATH=$SECRET_PATH"
echo "  3. Deploy the application:"
echo "     docker compose -f docker-compose.production.yml up -d"
echo ""
