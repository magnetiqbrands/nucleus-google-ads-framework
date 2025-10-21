#!/bin/bash
# Production Vault Entrypoint
# Authenticates to Vault, fetches secrets, exports to env, then execs uvicorn

set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-https://vault.example.com:8200}"
VAULT_TOKEN_FILE="/run/secrets/vault-token"
SECRET_PATH="${VAULT_SECRET_PATH:-secret/data/nucleus-ads-api}"
SECRETS_DIR="/run/secrets"

echo "==> Authenticating to Vault..."

# Read Vault token
if [[ ! -f "$VAULT_TOKEN_FILE" ]]; then
    echo "ERROR: Vault token not found at $VAULT_TOKEN_FILE"
    exit 1
fi

export VAULT_TOKEN=$(cat "$VAULT_TOKEN_FILE")
chmod 600 "$VAULT_TOKEN_FILE"

echo "==> Fetching secrets from $SECRET_PATH..."

# Fetch secrets from Vault
SECRETS=$(curl -sf -H "X-Vault-Token: $VAULT_TOKEN" \
    "$VAULT_ADDR/v1/$SECRET_PATH" | jq -r '.data.data')

if [[ -z "$SECRETS" ]] || [[ "$SECRETS" == "null" ]]; then
    echo "ERROR: Failed to fetch secrets from Vault"
    exit 1
fi

echo "==> Exporting Google Ads credentials..."

# Export Google Ads credentials
export GOOGLE_ADS_DEVELOPER_TOKEN=$(echo "$SECRETS" | jq -r '.google_ads_developer_token')
export GOOGLE_ADS_CLIENT_ID=$(echo "$SECRETS" | jq -r '.google_ads_client_id')
export GOOGLE_ADS_CLIENT_SECRET=$(echo "$SECRETS" | jq -r '.google_ads_client_secret')
export GOOGLE_ADS_REFRESH_TOKEN=$(echo "$SECRETS" | jq -r '.google_ads_refresh_token')
export GOOGLE_ADS_LOGIN_CUSTOMER_ID=$(echo "$SECRETS" | jq -r '.google_ads_login_customer_id')

# Write google-ads.yaml
cat > "$SECRETS_DIR/google-ads.yaml" <<EOF
developer_token: $GOOGLE_ADS_DEVELOPER_TOKEN
client_id: $GOOGLE_ADS_CLIENT_ID
client_secret: $GOOGLE_ADS_CLIENT_SECRET
refresh_token: $GOOGLE_ADS_REFRESH_TOKEN
login_customer_id: $GOOGLE_ADS_LOGIN_CUSTOMER_ID
use_proto_plus: True
EOF
chmod 600 "$SECRETS_DIR/google-ads.yaml"
export GOOGLE_ADS_YAML="$SECRETS_DIR/google-ads.yaml"

echo "==> Exporting JWT keys..."

# Extract and write JWT keys
echo "$SECRETS" | jq -r '.jwt_private_key' > "$SECRETS_DIR/jwks-private.pem"
echo "$SECRETS" | jq -r '.jwt_public_key' > "$SECRETS_DIR/jwks-public.pem"
chmod 600 "$SECRETS_DIR/jwks-private.pem"
chmod 644 "$SECRETS_DIR/jwks-public.pem"

export JWT_JWKS_PRIVATE_PATH="$SECRETS_DIR/jwks-private.pem"
export JWT_JWKS_PUBLIC_PATH="$SECRETS_DIR/jwks-public.pem"

# Database URL if present
if echo "$SECRETS" | jq -e '.database_url' > /dev/null 2>&1; then
    export DATABASE_URL=$(echo "$SECRETS" | jq -r '.database_url')
fi

echo "==> Secrets loaded. Starting application..."
echo "==> Command: $@"
echo ""

# Exec main process
exec "$@"
