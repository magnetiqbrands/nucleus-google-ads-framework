"""
Quota Governor for managing global and per-client API quota budgets.

Enforces SLA-based quota allocation and tracks consumption.
"""

import logging
from typing import Optional, Dict, Any
from enum import Enum

import redis.asyncio as redis

from core.errors import QuotaExceededError

logger = logging.getLogger(__name__)


class SLATier(str, Enum):
    """SLA tier classification."""

    GOLD = "gold"
    SILVER = "silver"
    BRONZE = "bronze"


# Reserve percentages for tier-based throttling
BRONZE_RESERVE_THRESHOLD = 0.15  # Bronze paused when global < 15%


class QuotaGovernor:
    """
    Manages quota budgets and enforces limits.

    Tracks both global and per-client quotas with SLA-aware throttling.
    """

    def __init__(self, redis_client: redis.Redis):
        """
        Initialize Quota Governor.

        Args:
            redis_client: Redis async client for quota state
        """
        self.redis = redis_client
        logger.info("QuotaGovernor initialized")

    async def can_run(
        self,
        client_id: str,
        units: int,
        tier: SLATier = SLATier.BRONZE
    ) -> bool:
        """
        Check if operation can run given quota constraints.

        Args:
            client_id: Client identifier
            units: Number of quota units needed
            tier: SLA tier of the client

        Returns:
            True if operation can proceed
        """
        try:
            # Get quota values
            global_remaining = int(await self.redis.get('quota:global_remaining') or 0)
            client_remaining = int(
                await self.redis.get(f'quota:client:{client_id}:remaining') or 0
            )
            global_daily = int(await self.redis.get('quota:global_daily') or 1)

            # Check if either quota is insufficient
            if global_remaining < units or client_remaining < units:
                logger.warning(
                    f"Quota insufficient for client {client_id}: "
                    f"global={global_remaining}, client={client_remaining}, needed={units}"
                )
                return False

            # Bronze tier throttling: pause if global quota < 15%
            if tier == SLATier.BRONZE:
                threshold = BRONZE_RESERVE_THRESHOLD * global_daily
                if global_remaining < threshold:
                    logger.warning(
                        f"Bronze tier throttled for client {client_id}: "
                        f"global_remaining={global_remaining} < threshold={threshold}"
                    )
                    return False

            return True

        except Exception as e:
            logger.error(f"Error checking quota for client {client_id}: {e}")
            # Fail open or closed based on policy - here we fail open (allow)
            return True

    async def charge(self, client_id: str, units: int) -> None:
        """
        Charge quota after successful operation.

        Args:
            client_id: Client identifier
            units: Number of quota units to charge
        """
        try:
            pipe = self.redis.pipeline()
            pipe.decrby('quota:global_remaining', units)
            pipe.decrby(f'quota:client:{client_id}:remaining', units)
            await pipe.execute()

            logger.debug(f"Charged {units} units to client {client_id}")

        except Exception as e:
            logger.error(f"Error charging quota for client {client_id}: {e}")
            # Don't raise - quota charge failure shouldn't break the operation

    async def refund(self, client_id: str, units: int) -> None:
        """
        Refund quota units (e.g., after failed operation).

        Args:
            client_id: Client identifier
            units: Number of quota units to refund
        """
        try:
            pipe = self.redis.pipeline()
            pipe.incrby('quota:global_remaining', units)
            pipe.incrby(f'quota:client:{client_id}:remaining', units)
            await pipe.execute()

            logger.debug(f"Refunded {units} units to client {client_id}")

        except Exception as e:
            logger.error(f"Error refunding quota for client {client_id}: {e}")

    async def get_client_tier(self, client_id: str) -> SLATier:
        """
        Get SLA tier for a client.

        Args:
            client_id: Client identifier

        Returns:
            SLA tier (defaults to BRONZE if not set)
        """
        try:
            tier_str = await self.redis.get(f'client:{client_id}:tier')
            if tier_str:
                return SLATier(tier_str.decode() if isinstance(tier_str, bytes) else tier_str)
        except Exception as e:
            logger.error(f"Error getting tier for client {client_id}: {e}")

        return SLATier.BRONZE

    async def set_client_tier(self, client_id: str, tier: SLATier) -> None:
        """
        Set SLA tier for a client.

        Args:
            client_id: Client identifier
            tier: SLA tier to set
        """
        try:
            await self.redis.set(f'client:{client_id}:tier', tier.value)
            logger.info(f"Set tier for client {client_id}: {tier.value}")
        except Exception as e:
            logger.error(f"Error setting tier for client {client_id}: {e}")
            raise

    async def is_client_paused(self, client_id: str) -> bool:
        """
        Check if a client is paused.

        Args:
            client_id: Client identifier

        Returns:
            True if client is paused
        """
        try:
            paused = await self.redis.get(f'client:{client_id}:paused')
            return paused == b'1' if isinstance(paused, bytes) else paused == '1'
        except Exception as e:
            logger.error(f"Error checking pause status for client {client_id}: {e}")
            return False

    async def pause_client(self, client_id: str) -> None:
        """
        Pause a client (no operations allowed).

        Args:
            client_id: Client identifier
        """
        try:
            await self.redis.set(f'client:{client_id}:paused', '1')
            logger.info(f"Paused client {client_id}")
        except Exception as e:
            logger.error(f"Error pausing client {client_id}: {e}")
            raise

    async def resume_client(self, client_id: str) -> None:
        """
        Resume a paused client.

        Args:
            client_id: Client identifier
        """
        try:
            await self.redis.delete(f'client:{client_id}:paused')
            logger.info(f"Resumed client {client_id}")
        except Exception as e:
            logger.error(f"Error resuming client {client_id}: {e}")
            raise

    async def reset_global_quota(self, daily_quota: int) -> None:
        """
        Reset global daily quota (typically called daily).

        Args:
            daily_quota: New daily quota amount
        """
        try:
            pipe = self.redis.pipeline()
            pipe.set('quota:global_daily', daily_quota)
            pipe.set('quota:global_remaining', daily_quota)
            await pipe.execute()

            logger.info(f"Reset global quota to {daily_quota}")
        except Exception as e:
            logger.error(f"Error resetting global quota: {e}")
            raise

    async def set_client_quota(self, client_id: str, quota: int) -> None:
        """
        Set quota for a specific client.

        Args:
            client_id: Client identifier
            quota: Quota amount
        """
        try:
            await self.redis.set(f'quota:client:{client_id}:remaining', quota)
            logger.info(f"Set quota for client {client_id}: {quota}")
        except Exception as e:
            logger.error(f"Error setting quota for client {client_id}: {e}")
            raise

    async def get_quota_status(self) -> Dict[str, Any]:
        """
        Get current quota status.

        Returns:
            Dictionary with quota information
        """
        try:
            global_remaining = int(await self.redis.get('quota:global_remaining') or 0)
            global_daily = int(await self.redis.get('quota:global_daily') or 0)

            return {
                "global_remaining": global_remaining,
                "global_daily": global_daily,
                "global_used": global_daily - global_remaining,
                "global_used_percent": round(
                    ((global_daily - global_remaining) / global_daily * 100) if global_daily > 0 else 0,
                    2
                ),
            }
        except Exception as e:
            logger.error(f"Error getting quota status: {e}")
            return {
                "global_remaining": 0,
                "global_daily": 0,
                "global_used": 0,
                "global_used_percent": 0,
            }

    async def get_client_quota_status(self, client_id: str) -> Dict[str, Any]:
        """
        Get quota status for a specific client.

        Args:
            client_id: Client identifier

        Returns:
            Dictionary with client quota information
        """
        try:
            remaining = int(await self.redis.get(f'quota:client:{client_id}:remaining') or 0)
            tier = await self.get_client_tier(client_id)
            paused = await self.is_client_paused(client_id)

            return {
                "client_id": client_id,
                "remaining": remaining,
                "tier": tier.value,
                "paused": paused,
            }
        except Exception as e:
            logger.error(f"Error getting client quota status for {client_id}: {e}")
            return {
                "client_id": client_id,
                "remaining": 0,
                "tier": SLATier.BRONZE.value,
                "paused": False,
            }
