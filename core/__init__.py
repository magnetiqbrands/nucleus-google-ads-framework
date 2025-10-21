"""Core modules for Google Ads Automation API."""

from core.errors import (
    AdsAPIError,
    AuthenticationError,
    AuthorizationError,
    QuotaExceededError,
    RateLimitError,
    ValidationError,
    NotFoundError,
    ConflictError,
    TimeoutError,
    CircuitBreakerError,
    ExternalAPIError,
    InternalError,
)
from core.cache import LRUCache, CacheManager, TTL_BY_SERVICE
from core.quota import QuotaGovernor, SLATier
from core.scheduler import PriorityScheduler, Operation
from core.google_ads_manager import (
    GoogleAdsManager,
    GAQLRequest,
    MutateRequest,
    create_google_ads_manager,
)

__all__ = [
    # Errors
    "AdsAPIError",
    "AuthenticationError",
    "AuthorizationError",
    "QuotaExceededError",
    "RateLimitError",
    "ValidationError",
    "NotFoundError",
    "ConflictError",
    "TimeoutError",
    "CircuitBreakerError",
    "ExternalAPIError",
    "InternalError",
    # Cache
    "LRUCache",
    "CacheManager",
    "TTL_BY_SERVICE",
    # Quota
    "QuotaGovernor",
    "SLATier",
    # Scheduler
    "PriorityScheduler",
    "Operation",
    # Google Ads Manager
    "GoogleAdsManager",
    "GAQLRequest",
    "MutateRequest",
    "create_google_ads_manager",
]
