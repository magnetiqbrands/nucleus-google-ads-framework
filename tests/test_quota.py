"""Tests for quota governor module."""

import pytest
from unittest.mock import AsyncMock, MagicMock
from core.quota import QuotaGovernor, SLATier


class TestQuotaGovernor:
    """Tests for QuotaGovernor implementation."""

    @pytest.fixture
    def mock_redis(self):
        """Create mock Redis client."""
        redis = AsyncMock()
        return redis

    @pytest.fixture
    def quota_governor(self, mock_redis):
        """Create QuotaGovernor instance with mock Redis."""
        return QuotaGovernor(mock_redis)

    @pytest.mark.asyncio
    async def test_can_run_with_sufficient_quota(self, quota_governor, mock_redis):
        """Test that operation can run when quota is sufficient."""
        # Setup
        mock_redis.get = AsyncMock(side_effect=lambda key: {
            'quota:global_remaining': b'1000',
            'quota:client:test_client:remaining': b'500',
            'quota:global_daily': b'10000',
        }.get(key, None))

        # Test
        can_run = await quota_governor.can_run("test_client", 100, SLATier.GOLD)

        assert can_run is True

    @pytest.mark.asyncio
    async def test_can_run_with_insufficient_global_quota(self, quota_governor, mock_redis):
        """Test that operation cannot run when global quota is insufficient."""
        # Setup
        mock_redis.get = AsyncMock(side_effect=lambda key: {
            'quota:global_remaining': b'50',  # Less than requested
            'quota:client:test_client:remaining': b'500',
            'quota:global_daily': b'10000',
        }.get(key, None))

        # Test
        can_run = await quota_governor.can_run("test_client", 100, SLATier.GOLD)

        assert can_run is False

    @pytest.mark.asyncio
    async def test_can_run_with_insufficient_client_quota(self, quota_governor, mock_redis):
        """Test that operation cannot run when client quota is insufficient."""
        # Setup
        mock_redis.get = AsyncMock(side_effect=lambda key: {
            'quota:global_remaining': b'1000',
            'quota:client:test_client:remaining': b'50',  # Less than requested
            'quota:global_daily': b'10000',
        }.get(key, None))

        # Test
        can_run = await quota_governor.can_run("test_client", 100, SLATier.GOLD)

        assert can_run is False

    @pytest.mark.asyncio
    async def test_bronze_tier_throttling(self, quota_governor, mock_redis):
        """Test that bronze tier is throttled when global quota is low."""
        # Setup - global remaining < 15% of daily
        mock_redis.get = AsyncMock(side_effect=lambda key: {
            'quota:global_remaining': b'1000',  # 10% of daily
            'quota:client:test_client:remaining': b'500',
            'quota:global_daily': b'10000',
        }.get(key, None))

        # Bronze should be throttled
        can_run = await quota_governor.can_run("test_client", 100, SLATier.BRONZE)
        assert can_run is False

        # Gold should still work
        can_run = await quota_governor.can_run("test_client", 100, SLATier.GOLD)
        assert can_run is True

    @pytest.mark.asyncio
    async def test_charge_quota(self, quota_governor, mock_redis):
        """Test quota charging."""
        # Setup
        pipeline_mock = AsyncMock()
        mock_redis.pipeline.return_value = pipeline_mock
        pipeline_mock.decrby.return_value = pipeline_mock
        pipeline_mock.execute.return_value = AsyncMock()

        # Test
        await quota_governor.charge("test_client", 100)

        # Verify
        assert pipeline_mock.decrby.call_count == 2
        pipeline_mock.execute.assert_called_once()

    @pytest.mark.asyncio
    async def test_refund_quota(self, quota_governor, mock_redis):
        """Test quota refund."""
        # Setup
        pipeline_mock = AsyncMock()
        mock_redis.pipeline.return_value = pipeline_mock
        pipeline_mock.incrby.return_value = pipeline_mock
        pipeline_mock.execute.return_value = AsyncMock()

        # Test
        await quota_governor.refund("test_client", 100)

        # Verify
        assert pipeline_mock.incrby.call_count == 2
        pipeline_mock.execute.assert_called_once()

    @pytest.mark.asyncio
    async def test_get_client_tier(self, quota_governor, mock_redis):
        """Test getting client tier."""
        # Setup
        mock_redis.get.return_value = b'gold'

        # Test
        tier = await quota_governor.get_client_tier("test_client")

        assert tier == SLATier.GOLD

    @pytest.mark.asyncio
    async def test_get_client_tier_default(self, quota_governor, mock_redis):
        """Test getting client tier defaults to bronze."""
        # Setup
        mock_redis.get.return_value = None

        # Test
        tier = await quota_governor.get_client_tier("test_client")

        assert tier == SLATier.BRONZE

    @pytest.mark.asyncio
    async def test_pause_and_resume_client(self, quota_governor, mock_redis):
        """Test pausing and resuming a client."""
        # Setup
        mock_redis.get.return_value = None
        mock_redis.set.return_value = AsyncMock()
        mock_redis.delete.return_value = AsyncMock()

        # Test pause
        await quota_governor.pause_client("test_client")
        mock_redis.set.assert_called_with('client:test_client:paused', '1')

        # Setup for is_paused check
        mock_redis.get.return_value = b'1'
        is_paused = await quota_governor.is_client_paused("test_client")
        assert is_paused is True

        # Test resume
        await quota_governor.resume_client("test_client")
        mock_redis.delete.assert_called_with('client:test_client:paused')

    @pytest.mark.asyncio
    async def test_reset_global_quota(self, quota_governor, mock_redis):
        """Test resetting global quota."""
        # Setup
        pipeline_mock = AsyncMock()
        mock_redis.pipeline.return_value = pipeline_mock
        pipeline_mock.set.return_value = pipeline_mock
        pipeline_mock.execute.return_value = AsyncMock()

        # Test
        await quota_governor.reset_global_quota(100000)

        # Verify
        assert pipeline_mock.set.call_count == 2
        pipeline_mock.execute.assert_called_once()

    @pytest.mark.asyncio
    async def test_get_quota_status(self, quota_governor, mock_redis):
        """Test getting quota status."""
        # Setup
        mock_redis.get = AsyncMock(side_effect=lambda key: {
            'quota:global_remaining': b'7500',
            'quota:global_daily': b'10000',
        }.get(key, b'0'))

        # Test
        status = await quota_governor.get_quota_status()

        assert status["global_remaining"] == 7500
        assert status["global_daily"] == 10000
        assert status["global_used"] == 2500
        assert status["global_used_percent"] == 25.0
