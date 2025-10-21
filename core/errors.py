"""
Error taxonomy and mapping for Google Ads API operations.

Provides typed errors and HTTP status code mapping for all error scenarios.
"""

from enum import Enum
from typing import Optional, Dict, Any
from dataclasses import dataclass


class ErrorCategory(str, Enum):
    """Error category classification."""

    AUTHENTICATION = "authentication"
    AUTHORIZATION = "authorization"
    QUOTA = "quota"
    RATE_LIMIT = "rate_limit"
    VALIDATION = "validation"
    NOT_FOUND = "not_found"
    CONFLICT = "conflict"
    INTERNAL = "internal"
    EXTERNAL_API = "external_api"
    TIMEOUT = "timeout"
    CIRCUIT_BREAKER = "circuit_breaker"


@dataclass
class ErrorDetail:
    """Detailed error information."""

    category: ErrorCategory
    code: str
    message: str
    http_status: int
    retryable: bool
    details: Optional[Dict[str, Any]] = None

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for API response."""
        result = {
            "category": self.category.value,
            "code": self.code,
            "message": self.message,
            "retryable": self.retryable,
        }
        if self.details:
            result["details"] = self.details
        return result


class AdsAPIError(Exception):
    """Base exception for all Ads API errors."""

    def __init__(
        self,
        message: str,
        category: ErrorCategory,
        code: str,
        http_status: int = 500,
        retryable: bool = False,
        details: Optional[Dict[str, Any]] = None
    ):
        super().__init__(message)
        self.error_detail = ErrorDetail(
            category=category,
            code=code,
            message=message,
            http_status=http_status,
            retryable=retryable,
            details=details or {}
        )


class AuthenticationError(AdsAPIError):
    """Authentication failed."""

    def __init__(self, message: str = "Authentication failed", details: Optional[Dict[str, Any]] = None):
        super().__init__(
            message=message,
            category=ErrorCategory.AUTHENTICATION,
            code="AUTH_FAILED",
            http_status=401,
            retryable=False,
            details=details
        )


class AuthorizationError(AdsAPIError):
    """Authorization/permission denied."""

    def __init__(self, message: str = "Permission denied", details: Optional[Dict[str, Any]] = None):
        super().__init__(
            message=message,
            category=ErrorCategory.AUTHORIZATION,
            code="PERMISSION_DENIED",
            http_status=403,
            retryable=False,
            details=details
        )


class QuotaExceededError(AdsAPIError):
    """Quota limit exceeded."""

    def __init__(
        self,
        message: str = "Quota exceeded",
        client_id: Optional[str] = None,
        details: Optional[Dict[str, Any]] = None
    ):
        error_details = details or {}
        if client_id:
            error_details["client_id"] = client_id

        super().__init__(
            message=message,
            category=ErrorCategory.QUOTA,
            code="QUOTA_EXCEEDED",
            http_status=429,
            retryable=True,
            details=error_details
        )


class RateLimitError(AdsAPIError):
    """Rate limit exceeded."""

    def __init__(
        self,
        message: str = "Rate limit exceeded",
        retry_after: Optional[int] = None,
        details: Optional[Dict[str, Any]] = None
    ):
        error_details = details or {}
        if retry_after:
            error_details["retry_after"] = retry_after

        super().__init__(
            message=message,
            category=ErrorCategory.RATE_LIMIT,
            code="RATE_LIMIT_EXCEEDED",
            http_status=429,
            retryable=True,
            details=error_details
        )


class ValidationError(AdsAPIError):
    """Request validation failed."""

    def __init__(self, message: str = "Validation failed", details: Optional[Dict[str, Any]] = None):
        super().__init__(
            message=message,
            category=ErrorCategory.VALIDATION,
            code="VALIDATION_ERROR",
            http_status=400,
            retryable=False,
            details=details
        )


class NotFoundError(AdsAPIError):
    """Resource not found."""

    def __init__(self, message: str = "Resource not found", resource: Optional[str] = None):
        details = {"resource": resource} if resource else None
        super().__init__(
            message=message,
            category=ErrorCategory.NOT_FOUND,
            code="NOT_FOUND",
            http_status=404,
            retryable=False,
            details=details
        )


class ConflictError(AdsAPIError):
    """Resource conflict (e.g., duplicate)."""

    def __init__(self, message: str = "Resource conflict", details: Optional[Dict[str, Any]] = None):
        super().__init__(
            message=message,
            category=ErrorCategory.CONFLICT,
            code="CONFLICT",
            http_status=409,
            retryable=False,
            details=details
        )


class TimeoutError(AdsAPIError):
    """Operation timeout."""

    def __init__(self, message: str = "Operation timed out", timeout_seconds: Optional[int] = None):
        details = {"timeout_seconds": timeout_seconds} if timeout_seconds else None
        super().__init__(
            message=message,
            category=ErrorCategory.TIMEOUT,
            code="TIMEOUT",
            http_status=504,
            retryable=True,
            details=details
        )


class CircuitBreakerError(AdsAPIError):
    """Circuit breaker is open."""

    def __init__(
        self,
        message: str = "Service temporarily unavailable (circuit breaker open)",
        retry_after: Optional[int] = None
    ):
        details = {"retry_after": retry_after} if retry_after else None
        super().__init__(
            message=message,
            category=ErrorCategory.CIRCUIT_BREAKER,
            code="CIRCUIT_BREAKER_OPEN",
            http_status=503,
            retryable=True,
            details=details
        )


class ExternalAPIError(AdsAPIError):
    """Error from Google Ads API."""

    def __init__(
        self,
        message: str,
        google_ads_error_code: Optional[str] = None,
        retryable: bool = False,
        details: Optional[Dict[str, Any]] = None
    ):
        error_details = details or {}
        if google_ads_error_code:
            error_details["google_ads_error_code"] = google_ads_error_code

        super().__init__(
            message=message,
            category=ErrorCategory.EXTERNAL_API,
            code="EXTERNAL_API_ERROR",
            http_status=502,
            retryable=retryable,
            details=error_details
        )


class InternalError(AdsAPIError):
    """Internal server error."""

    def __init__(self, message: str = "Internal server error", details: Optional[Dict[str, Any]] = None):
        super().__init__(
            message=message,
            category=ErrorCategory.INTERNAL,
            code="INTERNAL_ERROR",
            http_status=500,
            retryable=False,
            details=details
        )


# Google Ads error code to our error mapping
GOOGLE_ADS_ERROR_MAP: Dict[str, type[AdsAPIError]] = {
    "AUTHENTICATION_ERROR": AuthenticationError,
    "AUTHORIZATION_ERROR": AuthorizationError,
    "QUOTA_ERROR": QuotaExceededError,
    "RATE_LIMIT_ERROR": RateLimitError,
    "RESOURCE_EXHAUSTED": QuotaExceededError,
    "INVALID_ARGUMENT": ValidationError,
    "NOT_FOUND": NotFoundError,
    "ALREADY_EXISTS": ConflictError,
    "DEADLINE_EXCEEDED": TimeoutError,
    "INTERNAL_ERROR": InternalError,
    "UNAVAILABLE": ExternalAPIError,
}


def map_google_ads_exception(exception: Exception) -> AdsAPIError:
    """
    Map Google Ads SDK exception to our typed error.

    Args:
        exception: Google Ads SDK exception

    Returns:
        Mapped AdsAPIError instance
    """
    # Extract error code from Google Ads exception
    # This is a simplified version - actual implementation would parse GoogleAdsException
    error_code = getattr(exception, "error_code", "UNKNOWN")
    error_message = str(exception)

    # Map to our error type
    error_class = GOOGLE_ADS_ERROR_MAP.get(error_code, ExternalAPIError)

    # Determine if retryable
    retryable = error_code in [
        "QUOTA_ERROR",
        "RATE_LIMIT_ERROR",
        "RESOURCE_EXHAUSTED",
        "DEADLINE_EXCEEDED",
        "UNAVAILABLE"
    ]

    if error_class == ExternalAPIError:
        return error_class(
            message=error_message,
            google_ads_error_code=error_code,
            retryable=retryable,
            details={"original_error": error_code}
        )
    else:
        return error_class(message=error_message)
