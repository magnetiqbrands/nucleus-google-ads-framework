#!/bin/bash
set -euo pipefail

echo "==> Generating development JWT keys..."
mkdir -p /run/secrets

# Generate RSA key pair using Python cryptography
python3 << 'PYTHON_SCRIPT'
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.backends import default_backend

# Generate private key
private_key = rsa.generate_private_key(
    public_exponent=65537,
    key_size=2048,
    backend=default_backend()
)

# Serialize private key to PEM format
private_pem = private_key.private_bytes(
    encoding=serialization.Encoding.PEM,
    format=serialization.PrivateFormat.TraditionalOpenSSL,
    encryption_algorithm=serialization.NoEncryption()
)

# Get public key
public_key = private_key.public_key()

# Serialize public key to PEM format
public_pem = public_key.public_bytes(
    encoding=serialization.Encoding.PEM,
    format=serialization.PublicFormat.SubjectPublicKeyInfo
)

# Write keys to files
with open('/run/secrets/jwks-private.pem', 'wb') as f:
    f.write(private_pem)

with open('/run/secrets/jwks-public.pem', 'wb') as f:
    f.write(public_pem)

print("JWT keys generated successfully")
PYTHON_SCRIPT

chmod 600 /run/secrets/jwks-private.pem
chmod 644 /run/secrets/jwks-public.pem

export JWT_JWKS_PRIVATE_PATH="/run/secrets/jwks-private.pem"
export JWT_JWKS_PUBLIC_PATH="/run/secrets/jwks-public.pem"

echo "==> JWT keys generated"
echo "==> Starting uvicorn..."

# Start uvicorn
exec uvicorn apps.api_server:app --host 0.0.0.0 --port 8000 --workers 6
