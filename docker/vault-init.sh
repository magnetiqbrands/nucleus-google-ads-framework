#!/bin/bash
# Vault Secret Bootstrap Script
# Authenticates to Vault, fetches secrets, and launches the API server

set -euo pipefail

echo "==> Nucleus Ads API - Vault Secret Bootstrap"

# Configuration
VAULT_ADDR="${VAULT_ADDR:-https://vault.example.com:8200}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-}"
SECRET_PATH="${VAULT_SECRET_PATH:-secret/data/nucleus-ads-api}"
SECRETS_DIR="/run/secrets"
VAULT_TOKEN_FILE="${VAULT_TOKEN_FILE:-/run/secrets/vault-token}"
VAULT_ROLE_ID_FILE="${VAULT_ROLE_ID_FILE:-/run/secrets/vault-role-id}"
VAULT_SECRET_ID_FILE="${VAULT_SECRET_ID_FILE:-/run/secrets/vault-secret-id}"

# Ensure secrets directory exists with proper permissions
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

# Function to authenticate with Vault
authenticate_vault() {
    echo "==> Authenticating with Vault at $VAULT_ADDR"

    # Method 1: Token-based authentication
    if [[ -f "$VAULT_TOKEN_FILE" ]]; then
        echo "    Using token authentication"
        export VAULT_TOKEN=$(cat "$VAULT_TOKEN_FILE")
        chmod 600 "$VAULT_TOKEN_FILE"

    # Method 2: AppRole authentication
    elif [[ -f "$VAULT_ROLE_ID_FILE" ]] && [[ -f "$VAULT_SECRET_ID_FILE" ]]; then
        echo "    Using AppRole authentication"
        chmod 600 "$VAULT_ROLE_ID_FILE" "$VAULT_SECRET_ID_FILE"

        ROLE_ID=$(cat "$VAULT_ROLE_ID_FILE")
        SECRET_ID=$(cat "$VAULT_SECRET_ID_FILE")

        # Authenticate and get token
        AUTH_RESPONSE=$(curl -s -X POST \
            "$VAULT_ADDR/v1/auth/approle/login" \
            -d "{\"role_id\":\"$ROLE_ID\",\"secret_id\":\"$SECRET_ID\"}")

        export VAULT_TOKEN=$(echo "$AUTH_RESPONSE" | jq -r '.auth.client_token')

        if [[ -z "$VAULT_TOKEN" ]] || [[ "$VAULT_TOKEN" == "null" ]]; then
            echo "ERROR: Failed to authenticate with AppRole"
            exit 1
        fi

        echo "    AppRole authentication successful"

    else
        echo "ERROR: No Vault authentication method available"
        echo "       Provide either:"
        echo "       - Token file at $VAULT_TOKEN_FILE"
        echo "       - AppRole credentials at $VAULT_ROLE_ID_FILE and $VAULT_SECRET_ID_FILE"
        exit 1
    fi
}

# Function to fetch secrets from Vault
fetch_secrets() {
    echo "==> Fetching secrets from Vault path: $SECRET_PATH"

    # Fetch secrets
    SECRETS_RESPONSE=$(curl -s -H "X-Vault-Token: $VAULT_TOKEN" \
        ${VAULT_NAMESPACE:+-H "X-Vault-Namespace: $VAULT_NAMESPACE"} \
        "$VAULT_ADDR/v1/$SECRET_PATH")

    # Check if fetch was successful
    if ! echo "$SECRETS_RESPONSE" | jq -e '.data.data' > /dev/null 2>&1; then
        echo "ERROR: Failed to fetch secrets from Vault"
        echo "$SECRETS_RESPONSE"
        exit 1
    fi

    echo "    Secrets fetched successfully"

    # Extract secrets
    SECRETS_DATA=$(echo "$SECRETS_RESPONSE" | jq -r '.data.data')

    # Export Google Ads credentials
    export GOOGLE_ADS_DEVELOPER_TOKEN=$(echo "$SECRETS_DATA" | jq -r '.google_ads_developer_token')
    export GOOGLE_ADS_CLIENT_ID=$(echo "$SECRETS_DATA" | jq -r '.google_ads_client_id')
    export GOOGLE_ADS_CLIENT_SECRET=$(echo "$SECRETS_DATA" | jq -r '.google_ads_client_secret')
    export GOOGLE_ADS_REFRESH_TOKEN=$(echo "$SECRETS_DATA" | jq -r '.google_ads_refresh_token')
    export GOOGLE_ADS_LOGIN_CUSTOMER_ID=$(echo "$SECRETS_DATA" | jq -r '.google_ads_login_customer_id')

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
    echo "    Google Ads credentials written to $GOOGLE_ADS_YAML"

    # Extract JWT keys
    JWT_PRIVATE_KEY=$(echo "$SECRETS_DATA" | jq -r '.jwt_private_key')
    JWT_PUBLIC_KEY=$(echo "$SECRETS_DATA" | jq -r '.jwt_public_key')

    # Write JWT keys
    echo "$JWT_PRIVATE_KEY" > "$SECRETS_DIR/jwks-private.pem"
    echo "$JWT_PUBLIC_KEY" > "$SECRETS_DIR/jwks-public.pem"
    chmod 600 "$SECRETS_DIR/jwks-private.pem"
    chmod 644 "$SECRETS_DIR/jwks-public.pem"

    export JWT_JWKS_PRIVATE_PATH="$SECRETS_DIR/jwks-private.pem"
    export JWT_JWKS_PUBLIC_PATH="$SECRETS_DIR/jwks-public.pem"
    echo "    JWT keys written to $SECRETS_DIR/jwks-*.pem"

    # Export other configuration if present
    if echo "$SECRETS_DATA" | jq -e '.database_url' > /dev/null 2>&1; then
        export DATABASE_URL=$(echo "$SECRETS_DATA" | jq -r '.database_url')
        echo "    Database URL exported"
    fi

    echo "==> All secrets loaded successfully"
}

# Function to validate secrets
validate_secrets() {
    echo "==> Validating secrets"

    local errors=0

    # Check required Google Ads credentials
    for var in GOOGLE_ADS_DEVELOPER_TOKEN GOOGLE_ADS_CLIENT_ID GOOGLE_ADS_CLIENT_SECRET GOOGLE_ADS_REFRESH_TOKEN; do
        if [[ -z "${!var:-}" ]] || [[ "${!var}" == "null" ]]; then
            echo "ERROR: Missing required secret: $var"
            ((errors++))
        fi
    done

    # Check JWT keys
    if [[ ! -f "$JWT_JWKS_PRIVATE_PATH" ]] || [[ ! -f "$JWT_JWKS_PUBLIC_PATH" ]]; then
        echo "ERROR: Missing JWT key files"
        ((errors++))
    fi

    if [[ $errors -gt 0 ]]; then
        echo "ERROR: Secret validation failed with $errors errors"
        exit 1
    fi

    echo "    All required secrets validated"
}

# Function to cleanup on exit
cleanup() {
    echo "==> Cleaning up sensitive data"
    # Unset sensitive environment variables
    unset VAULT_TOKEN ROLE_ID SECRET_ID
    # Note: Keep application secrets as they're needed by the app
}

trap cleanup EXIT

# Main execution
main() {
    echo "========================================"
    echo "Nucleus Google Ads API - Vault Bootstrap"
    echo "========================================"

    # Authenticate with Vault
    authenticate_vault

    # Fetch secrets
    fetch_secrets

    # Validate secrets
    validate_secrets

    echo ""
    echo "==> Starting API server with Vault-provided secrets"
    echo "    Command: $@"
    echo ""

    # Execute the main application
    exec "$@"
}

# Run main with all arguments passed to script
main "$@"
