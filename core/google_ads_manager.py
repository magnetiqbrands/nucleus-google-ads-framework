"""
Google Ads API Manager with GAQL search and mutate wrappers.

Provides a unified interface for Google Ads operations with quota/scheduler integration.
"""

import logging
from typing import Any, Dict, List, Optional, Callable
from dataclasses import dataclass
from enum import Enum

from tenacity import (
    retry,
    stop_after_attempt,
    wait_exponential_jitter,
    retry_if_exception_type,
)

from core.errors import (
    ExternalAPIError,
    QuotaExceededError,
    RateLimitError,
    ValidationError,
    map_google_ads_exception,
)
from core.quota import QuotaGovernor, SLATier
from core.scheduler import PriorityScheduler
from core.cache import CacheManager

logger = logging.getLogger(__name__)


class OperationType(str, Enum):
    """Types of Google Ads operations."""

    SEARCH = "search"
    MUTATE = "mutate"
    GET = "get"


@dataclass
class GAQLRequest:
    """GAQL query request."""

    query: str
    client_id: str
    page_size: int = 1000
    cache_enabled: bool = True
    service_type: str = "reporting"


@dataclass
class MutateRequest:
    """Mutate operation request."""

    operations: List[Dict[str, Any]]
    client_id: str
    operation_type: str  # e.g., "campaign", "ad_group", "keyword"
    validate_only: bool = False


class MockGoogleAdsClient:
    """
    Mock Google Ads client for testing.

    Simulates Google Ads API responses without making real API calls.
    """

    def __init__(self, config: Dict[str, Any]):
        """
        Initialize mock client.

        Args:
            config: Client configuration
        """
        self.config = config
        logger.info("MockGoogleAdsClient initialized")

    def search(self, customer_id: str, query: str, page_size: int = 1000) -> List[Dict[str, Any]]:
        """
        Mock search operation.

        Args:
            customer_id: Google Ads customer ID
            query: GAQL query
            page_size: Results per page

        Returns:
            Mock search results
        """
        logger.debug(f"Mock search for customer {customer_id}: {query}")

        # Return mock data
        return [
            {
                "campaign": {
                    "id": "123456789",
                    "name": "Mock Campaign",
                    "status": "ENABLED",
                },
                "metrics": {
                    "impressions": 1000,
                    "clicks": 50,
                    "cost_micros": 5000000,
                }
            }
        ]

    def mutate(
        self,
        customer_id: str,
        operations: List[Dict[str, Any]],
        validate_only: bool = False
    ) -> Dict[str, Any]:
        """
        Mock mutate operation.

        Args:
            customer_id: Google Ads customer ID
            operations: List of operations to perform
            validate_only: If True, only validate without applying

        Returns:
            Mock mutate response
        """
        logger.debug(
            f"Mock mutate for customer {customer_id}: "
            f"{len(operations)} operations (validate_only={validate_only})"
        )

        # Return mock response
        return {
            "results": [
                {"resource_name": f"customers/{customer_id}/campaigns/{i}", "operation_id": str(i)}
                for i in range(len(operations))
            ],
            "partial_failure_error": None,
        }


class GoogleAdsManager:
    """
    Manager for Google Ads API operations.

    Integrates with quota governor, scheduler, and cache for reliable operation.
    """

    def __init__(
        self,
        client: Any,  # GoogleAdsClient or MockGoogleAdsClient
        quota_governor: QuotaGovernor,
        scheduler: PriorityScheduler,
        cache_manager: CacheManager,
        use_mock: bool = False,
    ):
        """
        Initialize Google Ads Manager.

        Args:
            client: Google Ads client (real or mock)
            quota_governor: Quota governor instance
            scheduler: Priority scheduler instance
            cache_manager: Cache manager instance
            use_mock: Whether to use mock client
        """
        self.client = client
        self.quota_governor = quota_governor
        self.scheduler = scheduler
        self.cache_manager = cache_manager
        self.use_mock = use_mock
        logger.info(f"GoogleAdsManager initialized (mock={use_mock})")

    async def execute_gaql(
        self,
        request: GAQLRequest,
        urgency: int = 50,
    ) -> List[Dict[str, Any]]:
        """
        Execute GAQL search query with quota/cache/scheduler integration.

        Args:
            request: GAQL request parameters
            urgency: Operation urgency (0-99)

        Returns:
            Query results
        """
        # Check cache first
        if request.cache_enabled:
            cache_key = self.cache_manager.build_cache_key(
                client_id=request.client_id,
                operation="gaql",
                query=request.query,
                page_size=request.page_size,
            )
            cached_result = await self.cache_manager.get(cache_key, request.service_type)
            if cached_result is not None:
                logger.info(f"Cache hit for GAQL query (client={request.client_id})")
                return cached_result

        # Get client tier
        tier = await self.quota_governor.get_client_tier(request.client_id)

        # Check if client is paused
        if await self.quota_governor.is_client_paused(request.client_id):
            raise QuotaExceededError(
                f"Client {request.client_id} is paused",
                client_id=request.client_id
            )

        # Check quota (estimated 10 units per query)
        quota_units = 10
        if not await self.quota_governor.can_run(request.client_id, quota_units, tier):
            raise QuotaExceededError(
                "Insufficient quota for GAQL query",
                client_id=request.client_id
            )

        # Execute via scheduler
        result = await self._execute_operation(
            operation_fn=self._search_with_retry,
            client_id=request.client_id,
            tier=tier,
            urgency=urgency,
            quota_units=quota_units,
            customer_id=request.client_id,
            query=request.query,
            page_size=request.page_size,
        )

        # Cache result
        if request.cache_enabled and result:
            await self.cache_manager.set(
                cache_key,
                result,
                service_type=request.service_type
            )

        return result

    async def execute_mutate(
        self,
        request: MutateRequest,
        urgency: int = 70,
    ) -> Dict[str, Any]:
        """
        Execute mutate operation with quota/scheduler integration.

        Args:
            request: Mutate request parameters
            urgency: Operation urgency (0-99, higher for mutations)

        Returns:
            Mutate response
        """
        # Get client tier
        tier = await self.quota_governor.get_client_tier(request.client_id)

        # Check if client is paused
        if await self.quota_governor.is_client_paused(request.client_id):
            raise QuotaExceededError(
                f"Client {request.client_id} is paused",
                client_id=request.client_id
            )

        # Check quota (estimated 50 units per mutate operation)
        quota_units = 50 * len(request.operations)
        if not await self.quota_governor.can_run(request.client_id, quota_units, tier):
            raise QuotaExceededError(
                "Insufficient quota for mutate operation",
                client_id=request.client_id
            )

        # Execute via scheduler
        result = await self._execute_operation(
            operation_fn=self._mutate_with_retry,
            client_id=request.client_id,
            tier=tier,
            urgency=urgency,
            quota_units=quota_units,
            customer_id=request.client_id,
            operations=request.operations,
            validate_only=request.validate_only,
        )

        return result

    async def _execute_operation(
        self,
        operation_fn: Callable,
        client_id: str,
        tier: SLATier,
        urgency: int,
        quota_units: int,
        **kwargs: Any,
    ) -> Any:
        """
        Execute operation through scheduler with quota management.

        Args:
            operation_fn: Operation function to execute
            client_id: Client ID
            tier: SLA tier
            urgency: Operation urgency
            quota_units: Quota units to charge
            **kwargs: Arguments for operation_fn

        Returns:
            Operation result
        """
        result_container: List[Any] = [None]
        error_container: List[Optional[Exception]] = [None]

        async def wrapped_operation() -> None:
            """Wrapper that handles quota charging and error capture."""
            try:
                result = await operation_fn(**kwargs)
                result_container[0] = result
                # Charge quota on success
                await self.quota_governor.charge(client_id, quota_units)
            except Exception as e:
                error_container[0] = e
                # Optionally refund quota on certain errors
                logger.error(f"Operation failed for client {client_id}: {e}")

        # Submit to scheduler
        await self.scheduler.submit(
            fn=wrapped_operation,
            client_id=client_id,
            tier=tier,
            urgency=urgency,
        )

        # Wait for completion
        await self.scheduler.wait_for_completion(timeout=120.0)

        # Check for errors
        if error_container[0]:
            raise error_container[0]

        return result_container[0]

    @retry(
        stop=stop_after_attempt(3),
        wait=wait_exponential_jitter(initial=1, max=10),
        retry=retry_if_exception_type((RateLimitError, ExternalAPIError)),
        reraise=True,
    )
    async def _search_with_retry(
        self,
        customer_id: str,
        query: str,
        page_size: int,
    ) -> List[Dict[str, Any]]:
        """
        Execute GAQL search with retry logic.

        Args:
            customer_id: Google Ads customer ID
            query: GAQL query
            page_size: Results per page

        Returns:
            Search results
        """
        try:
            # Use mock or real client
            results = self.client.search(customer_id, query, page_size)
            return results

        except Exception as e:
            # Map to our error types
            raise map_google_ads_exception(e)

    @retry(
        stop=stop_after_attempt(3),
        wait=wait_exponential_jitter(initial=1, max=10),
        retry=retry_if_exception_type((RateLimitError, ExternalAPIError)),
        reraise=True,
    )
    async def _mutate_with_retry(
        self,
        customer_id: str,
        operations: List[Dict[str, Any]],
        validate_only: bool,
    ) -> Dict[str, Any]:
        """
        Execute mutate operation with retry logic.

        Args:
            customer_id: Google Ads customer ID
            operations: Operations to execute
            validate_only: Validation mode

        Returns:
            Mutate response
        """
        try:
            # Use mock or real client
            response = self.client.mutate(customer_id, operations, validate_only)
            return response

        except Exception as e:
            # Map to our error types
            raise map_google_ads_exception(e)


def create_google_ads_manager(
    quota_governor: QuotaGovernor,
    scheduler: PriorityScheduler,
    cache_manager: CacheManager,
    use_mock: bool = True,
    config: Optional[Dict[str, Any]] = None,
) -> GoogleAdsManager:
    """
    Factory function to create GoogleAdsManager.

    Args:
        quota_governor: Quota governor instance
        scheduler: Scheduler instance
        cache_manager: Cache manager instance
        use_mock: Whether to use mock client
        config: Google Ads client configuration

    Returns:
        Configured GoogleAdsManager instance
    """
    if use_mock:
        client = MockGoogleAdsClient(config or {})
    else:
        # In production, initialize real Google Ads client here
        # from google.ads.googleads.client import GoogleAdsClient
        # client = GoogleAdsClient.load_from_dict(config)
        logger.warning("Real Google Ads client not implemented, using mock")
        client = MockGoogleAdsClient(config or {})

    return GoogleAdsManager(
        client=client,
        quota_governor=quota_governor,
        scheduler=scheduler,
        cache_manager=cache_manager,
        use_mock=use_mock,
    )
