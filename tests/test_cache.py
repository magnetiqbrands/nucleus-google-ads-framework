"""Tests for caching module."""

import pytest
from core.cache import LRUCache, CacheStats


class TestLRUCache:
    """Tests for LRU cache implementation."""

    def test_cache_set_and_get(self):
        """Test basic set and get operations."""
        cache = LRUCache(maxsize=10)

        cache.set("key1", "value1")
        assert cache.get("key1") == "value1"

    def test_cache_miss(self):
        """Test cache miss returns None."""
        cache = LRUCache(maxsize=10)

        assert cache.get("nonexistent") is None

    def test_cache_eviction(self):
        """Test that cache evicts oldest item when full."""
        cache = LRUCache(maxsize=3)

        # Fill cache
        cache.set("key1", "value1")
        cache.set("key2", "value2")
        cache.set("key3", "value3")

        # Add one more - should evict key1
        cache.set("key4", "value4")

        assert cache.get("key1") is None
        assert cache.get("key2") == "value2"
        assert cache.get("key3") == "value3"
        assert cache.get("key4") == "value4"

    def test_cache_lru_ordering(self):
        """Test that accessing items updates LRU order."""
        cache = LRUCache(maxsize=3)

        cache.set("key1", "value1")
        cache.set("key2", "value2")
        cache.set("key3", "value3")

        # Access key1 to move it to end
        cache.get("key1")

        # Add key4 - should evict key2 (not key1)
        cache.set("key4", "value4")

        assert cache.get("key1") == "value1"
        assert cache.get("key2") is None
        assert cache.get("key3") == "value3"
        assert cache.get("key4") == "value4"

    def test_cache_stats(self):
        """Test cache statistics tracking."""
        cache = LRUCache(maxsize=10)

        # Initial stats
        stats = cache.get_stats()
        assert stats.hits == 0
        assert stats.misses == 0
        assert stats.sets == 0

        # Set and hit
        cache.set("key1", "value1")
        cache.get("key1")

        stats = cache.get_stats()
        assert stats.hits == 1
        assert stats.misses == 0
        assert stats.sets == 1

        # Miss
        cache.get("key2")

        stats = cache.get_stats()
        assert stats.hits == 1
        assert stats.misses == 1

        # Check hit rate
        assert stats.hit_rate == 50.0

    def test_cache_delete(self):
        """Test cache delete operation."""
        cache = LRUCache(maxsize=10)

        cache.set("key1", "value1")
        assert cache.delete("key1") is True
        assert cache.get("key1") is None
        assert cache.delete("key1") is False

    def test_cache_clear(self):
        """Test cache clear operation."""
        cache = LRUCache(maxsize=10)

        cache.set("key1", "value1")
        cache.set("key2", "value2")

        cache.clear()

        assert cache.get("key1") is None
        assert cache.get("key2") is None
        assert cache.size() == 0

    def test_cache_size(self):
        """Test cache size tracking."""
        cache = LRUCache(maxsize=10)

        assert cache.size() == 0

        cache.set("key1", "value1")
        assert cache.size() == 1

        cache.set("key2", "value2")
        assert cache.size() == 2

        cache.delete("key1")
        assert cache.size() == 1
