"""
JWT authentication and RBAC for API endpoints.

Implements RS256 JWT verification with role-based access control.
"""

import json
import logging
from datetime import datetime, timedelta
from typing import Optional, List, Dict, Any
from enum import Enum
from pathlib import Path

import jwt
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel

from core.errors import AuthenticationError, AuthorizationError

logger = logging.getLogger(__name__)


class Role(str, Enum):
    """User roles for RBAC."""

    ADMIN = "admin"
    OPS = "ops"
    VIEWER = "viewer"


class TokenData(BaseModel):
    """Decoded JWT token data."""

    sub: str  # Subject (user ID)
    role: Role
    aud: str  # Audience
    iss: str  # Issuer
    exp: datetime
    iat: datetime


class JWTConfig:
    """JWT configuration."""

    def __init__(
        self,
        public_key_path: str,
        private_key_path: Optional[str] = None,
        algorithm: str = "RS256",
        audience: str = "ads-api",
        issuer: str = "ads-auth",
        expiry_minutes: int = 15,
    ):
        """
        Initialize JWT configuration.

        Args:
            public_key_path: Path to RS256 public key (for verification)
            private_key_path: Path to RS256 private key (for signing)
            algorithm: JWT algorithm (default RS256)
            audience: Expected audience claim
            issuer: Expected issuer claim
            expiry_minutes: Token expiry in minutes
        """
        self.algorithm = algorithm
        self.audience = audience
        self.issuer = issuer
        self.expiry_minutes = expiry_minutes

        # Load public key for verification
        public_path = Path(public_key_path)
        if public_path.exists():
            with open(public_path, 'r') as f:
                self.public_key = f.read()
        else:
            logger.warning(f"Public key not found at {public_key_path}, using mock key")
            self.public_key = self._generate_mock_key()

        # Load private key for signing (optional)
        self.private_key = None
        if private_key_path:
            private_path = Path(private_key_path)
            if private_path.exists():
                with open(private_path, 'r') as f:
                    self.private_key = f.read()

    def _generate_mock_key(self) -> str:
        """Generate a mock public key for development."""
        # In production, this should never be used
        logger.warning("Using mock JWT public key - NOT FOR PRODUCTION")
        from cryptography.hazmat.primitives.asymmetric import rsa
        from cryptography.hazmat.primitives import serialization

        private_key = rsa.generate_private_key(
            public_exponent=65537,
            key_size=2048,
        )

        # Save private key for mock signing
        self.private_key = private_key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption()
        ).decode()

        # Return public key
        public_key = private_key.public_key()
        return public_key.public_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PublicFormat.SubjectPublicKeyInfo
        ).decode()


# Global JWT config (will be initialized on app startup)
_jwt_config: Optional[JWTConfig] = None


def init_jwt_config(config: JWTConfig) -> None:
    """Initialize global JWT configuration."""
    global _jwt_config
    _jwt_config = config
    logger.info("JWT configuration initialized")


def get_jwt_config() -> JWTConfig:
    """Get JWT configuration."""
    if _jwt_config is None:
        raise RuntimeError("JWT configuration not initialized")
    return _jwt_config


# HTTP Bearer security scheme
security = HTTPBearer()


def verify_token(token: str, config: Optional[JWTConfig] = None) -> TokenData:
    """
    Verify and decode JWT token.

    Args:
        token: JWT token string
        config: JWT configuration (uses global if not provided)

    Returns:
        Decoded token data

    Raises:
        AuthenticationError: If token is invalid
    """
    if config is None:
        config = get_jwt_config()

    try:
        # Decode and verify token
        payload = jwt.decode(
            token,
            config.public_key,
            algorithms=[config.algorithm],
            audience=config.audience,
            issuer=config.issuer,
        )

        # Parse token data
        token_data = TokenData(
            sub=payload["sub"],
            role=Role(payload["role"]),
            aud=payload["aud"],
            iss=payload["iss"],
            exp=datetime.fromtimestamp(payload["exp"]),
            iat=datetime.fromtimestamp(payload["iat"]),
        )

        return token_data

    except jwt.ExpiredSignatureError:
        raise AuthenticationError("Token has expired")
    except jwt.InvalidAudienceError:
        raise AuthenticationError("Invalid token audience")
    except jwt.InvalidIssuerError:
        raise AuthenticationError("Invalid token issuer")
    except jwt.InvalidTokenError as e:
        raise AuthenticationError(f"Invalid token: {str(e)}")
    except Exception as e:
        logger.error(f"Token verification error: {e}")
        raise AuthenticationError("Token verification failed")


def create_token(
    user_id: str,
    role: Role,
    config: Optional[JWTConfig] = None
) -> str:
    """
    Create a new JWT token (for testing/development).

    Args:
        user_id: User identifier
        role: User role
        config: JWT configuration (uses global if not provided)

    Returns:
        JWT token string
    """
    if config is None:
        config = get_jwt_config()

    if not config.private_key:
        raise RuntimeError("Private key not configured for token creation")

    now = datetime.utcnow()
    payload = {
        "sub": user_id,
        "role": role.value,
        "aud": config.audience,
        "iss": config.issuer,
        "iat": now,
        "exp": now + timedelta(minutes=config.expiry_minutes),
    }

    token = jwt.encode(payload, config.private_key, algorithm=config.algorithm)
    return token


async def get_current_user(
    credentials: HTTPAuthorizationCredentials = Depends(security)
) -> TokenData:
    """
    FastAPI dependency to get current authenticated user.

    Args:
        credentials: HTTP Bearer credentials

    Returns:
        Decoded token data

    Raises:
        HTTPException: If authentication fails
    """
    try:
        token_data = verify_token(credentials.credentials)
        return token_data
    except AuthenticationError as e:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=str(e),
            headers={"WWW-Authenticate": "Bearer"},
        )


def require_role(allowed_roles: List[Role]):
    """
    Create a dependency that requires specific roles.

    Args:
        allowed_roles: List of allowed roles

    Returns:
        FastAPI dependency function
    """
    async def role_checker(
        token_data: TokenData = Depends(get_current_user)
    ) -> TokenData:
        if token_data.role not in allowed_roles:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=f"Insufficient permissions. Required roles: {[r.value for r in allowed_roles]}",
            )
        return token_data

    return role_checker


# Common role dependencies
require_admin = require_role([Role.ADMIN])
require_ops = require_role([Role.ADMIN, Role.OPS])
require_viewer = require_role([Role.ADMIN, Role.OPS, Role.VIEWER])


def require_roles(*roles: Role):
    """
    Decorator for requiring specific roles.

    Usage:
        @require_roles(Role.ADMIN, Role.OPS)
        async def my_endpoint():
            pass
    """
    return require_role(list(roles))
