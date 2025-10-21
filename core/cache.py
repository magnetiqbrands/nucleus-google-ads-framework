"""
2-tier caching system: In-process LRU + Redis.

Provides fast in-memory caching with Redis fallback for distributed scenarios.
"""

import json
import time
from collections import OrderedDict
from typing import Optional, Any, Dict
from dataclasses import dataclass
import logging

import redis.asyncio as redis

logger = logging.getLogger(__name__)


# TTL policy by service type (in seconds)
TTL_BY_SERVICE: Dict[str, int] = {
    'reporting': 300,      # 5 min
    'campaign': 1800,      # 30 min
    'keyword': 900,        # 15 min
    'budget': 3600,        # 1 hour
    'customer': 86400,     # 1 day
    'default': 300,        # 5 min
}


@dataclass
class CacheStats:
    """Cache statistics for monitoring."""

    hits: int = 0
    misses: int = 0
    sets: int = 0
    evictions: int = 0

    @property
    def hit_rate(self) -> float:
        """Calculate cache hit rate."""
        total = self.hits + self.misses
        return (self.hits / total * 100) if total > 0 else 0.0

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "hits": self.hits,
            "misses": self.misses,
            "sets": self.sets,
            "evictions": self.evictions,
            "hit_rate": round(self.hit_rate, 2),
        }


class LRUCache:
    """Simple in-process LRU cache with metrics."""

    def __init__(self, maxsize: int = 10_000):
        """
        Initialize LRU cache.

        Args:
            maxsize: Maximum number of entries to cache
        """
        self.maxsize = maxsize
        self.cache: OrderedDict[str, Any] = OrderedDict()
        self.stats = CacheStats()

    def get(self, key: str) -> Optional[Any]:
        """
        Get value from cache.

        Args:
            key: Cache key

        Returns:
            Cached value or None if not found
        """
        value = self.cache.get(key)
        if value is not None:
            self.cache.move_to_end(key)
            self.stats.hits += 1
            logger.debug(f"LRU cache hit: {key}")
            return value

        self.stats.misses += 1
        logger.debug(f"LRU cache miss: {key}")
        return None

    def set(self, key: str, value: Any) -> None:
        """
        Set value in cache.

        Args:
            key: Cache key
            value: Value to cache
        """
        # Update existing or add new
        self.cache[key] = value
        self.cache.move_to_end(key)

        # Evict if over limit (only for new keys)
        if len(self.cache) > self.maxsize:
            evicted_key = self.cache.popitem(last=False)
            self.stats.evictions += 1
            logger.debug(f"LRU cache eviction: {evicted_key[0]}")

        self.stats.sets += 1

    def delete(self, key: str) -> bool:
        """
        Delete key from cache.

        Args:
            key: Cache key

        Returns:
            True if key was deleted, False if not found
        """
        if key in self.cache:
            del self.cache[key]
            return True
        return False

    def clear(self) -> None:
        """Clear all cache entries."""
        self.cache.clear()
        logger.info("LRU cache cleared")

    def size(self) -> int:
        """Get current cache size."""
        return len(self.cache)

    def get_stats(self) -> CacheStats:
        """Get cache statistics."""
        return self.stats


class CacheManager:
    """
    2-tier cache manager: LRU + Redis.

    Provides unified interface for both in-memory and distributed caching.
    """

    def __init__(
        self,
        redis_client: redis.Redis,
        lru_maxsize: int = 10_000
    ):
        """
        Initialize cache manager.

        Args:
            redis_client: Redis async client
            lru_maxsize: Maximum size of LRU cache
        """
        self.redis = redis_client
        self.hot_cache = LRUCache(maxsize=lru_maxsize)
        logger.info(f"CacheManager initialized (LRU size: {lru_maxsize})")

    async def get(self, cache_key: str, service_type: str = "default") -> Optional[Any]:
        """
        Get value from cache (checks LRU first, then Redis).

        Args:
            cache_key: Cache key
            service_type: Service type for TTL mapping

        Returns:
            Cached value or None
        """
        # Try LRU first
        result = self.hot_cache.get(cache_key)
        if result is not None:
            return result

        # Try Redis
        try:
            cached = await self.redis.get(f"cache:{cache_key}")
            if cached:
                data = json.loads(cached)
                # Promote to LRU
                self.hot_cache.set(cache_key, data)
                logger.debug(f"Redis cache hit (promoted to LRU): {cache_key}")
                return data
        except Exception as e:
            logger.error(f"Redis get error for key {cache_key}: {e}")

        return None

    async def set(
        self,
        cache_key: str,
        value: Any,
        service_type: str = "default",
        ttl: Optional[int] = None
    ) -> None:
        """
        Set value in cache (both LRU and Redis).

        Args:
            cache_key: Cache key
            value: Value to cache
            service_type: Service type for TTL mapping
            ttl: Optional explicit TTL (overrides service type TTL)
        """
        # Determine TTL
        cache_ttl = ttl if ttl is not None else TTL_BY_SERVICE.get(service_type, 300)

        # Set in LRU
        self.hot_cache.set(cache_key, value)

        # Set in Redis with TTL
        try:
            payload = json.dumps(value)
            await self.redis.setex(f"cache:{cache_key}", cache_ttl, payload)
            logger.debug(f"Cached in LRU+Redis: {cache_key} (TTL: {cache_ttl}s)")
        except Exception as e:
            logger.error(f"Redis set error for key {cache_key}: {e}")

    async def delete(self, cache_key: str) -> None:
        """
        Delete key from both LRU and Redis.

        Args:
            cache_key: Cache key
        """
        # Delete from LRU
        self.hot_cache.delete(cache_key)

        # Delete from Redis
        try:
            await self.redis.delete(f"cache:{cache_key}")
            logger.debug(f"Deleted from cache: {cache_key}")
        except Exception as e:
            logger.error(f"Redis delete error for key {cache_key}: {e}")

    async def clear_pattern(self, pattern: str) -> int:
        """
        Clear all keys matching a pattern from Redis.

        Args:
            pattern: Redis key pattern (e.g., "cache:client:123:*")

        Returns:
            Number of keys deleted
        """
        try:
            keys = []
            async for key in self.redis.scan_iter(match=pattern):
                keys.append(key)

            if keys:
                deleted = await self.redis.delete(*keys)
                logger.info(f"Cleared {deleted} keys matching pattern: {pattern}")
                return deleted
        except Exception as e:
            logger.error(f"Redis clear pattern error for {pattern}: {e}")

        return 0

    def get_stats(self) -> Dict[str, Any]:
        """
        Get cache statistics.

        Returns:
            Dictionary with LRU and Redis stats
        """
        lru_stats = self.hot_cache.get_stats()
        return {
            "lru": lru_stats.to_dict(),
            "lru_size": self.hot_cache.size(),
            "lru_maxsize": self.hot_cache.maxsize,
        }

    def build_cache_key(
        self,
        client_id: str,
        operation: str,
        **params: Any
    ) -> str:
        """
        Build a standardized cache key.

        Args:
            client_id: Client ID
            operation: Operation name
            **params: Additional parameters to include in key

        Returns:
            Standardized cache key
        """
        # Sort params for consistency
        param_str = ":".join(f"{k}={v}" for k, v in sorted(params.items()))
        if param_str:
            return f"client:{client_id}:{operation}:{param_str}"
        return f"client:{client_id}:{operation}"
