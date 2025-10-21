"""
Priority Scheduler for SLA-aware task execution.

Routes operations based on SLA tier and urgency with fairness guarantees.
"""

import asyncio
import time
import logging
from typing import Callable, Any, Coroutine, Optional, Dict
from dataclasses import dataclass
from enum import Enum

from core.quota import SLATier

logger = logging.getLogger(__name__)


# SLA weight mapping (higher weight = higher priority)
SLA_WEIGHT: Dict[str, int] = {
    SLATier.GOLD.value: 3,
    SLATier.SILVER.value: 2,
    SLATier.BRONZE.value: 1,
}


@dataclass
class Operation:
    """
    Represents a scheduled operation.

    Operations are prioritized by tier and urgency.
    """

    priority: int
    timestamp: float
    fn: Callable[..., Coroutine[Any, Any, Any]]
    args: tuple
    kwargs: dict
    client_id: str
    tier: SLATier
    urgency: int

    def __lt__(self, other: 'Operation') -> bool:
        """
        Compare operations for priority queue ordering.

        Lower priority value = higher priority (processed first).
        For same priority, earlier timestamp wins (FIFO).
        """
        if self.priority != other.priority:
            return self.priority < other.priority
        return self.timestamp < other.timestamp

    async def execute(self) -> Any:
        """Execute the operation."""
        return await self.fn(*self.args, **self.kwargs)


class SchedulerStats:
    """Statistics for scheduler monitoring."""

    def __init__(self) -> None:
        self.submitted: int = 0
        self.completed: int = 0
        self.failed: int = 0
        self.by_tier: Dict[str, int] = {tier.value: 0 for tier in SLATier}

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "submitted": self.submitted,
            "completed": self.completed,
            "failed": self.failed,
            "pending": self.submitted - self.completed - self.failed,
            "by_tier": self.by_tier,
        }


class PriorityScheduler:
    """
    SLA-aware priority scheduler.

    Manages a worker pool that processes operations based on priority,
    which is determined by SLA tier and urgency.
    """

    def __init__(self, workers: int = 8):
        """
        Initialize priority scheduler.

        Args:
            workers: Number of concurrent worker tasks
        """
        self.workers = workers
        self.queue: asyncio.PriorityQueue[Operation] = asyncio.PriorityQueue()
        self.stats = SchedulerStats()
        self._worker_tasks: list[asyncio.Task[None]] = []
        self._running = False
        logger.info(f"PriorityScheduler initialized with {workers} workers")

    async def submit(
        self,
        fn: Callable[..., Coroutine[Any, Any, Any]],
        client_id: str,
        tier: SLATier,
        urgency: int = 50,
        *args: Any,
        **kwargs: Any
    ) -> None:
        """
        Submit an operation for execution.

        Args:
            fn: Async function to execute
            client_id: Client identifier
            tier: SLA tier
            urgency: Urgency level (0-99, higher = more urgent)
            *args: Positional arguments for fn
            **kwargs: Keyword arguments for fn
        """
        # Calculate priority: base priority from urgency, divided by tier weight
        # Lower priority value = higher priority in queue
        urgency_clamped = max(0, min(urgency, 99))
        base_priority = 100 - urgency_clamped
        tier_weight = SLA_WEIGHT.get(tier.value, 1)
        priority = base_priority // tier_weight

        operation = Operation(
            priority=priority,
            timestamp=time.time(),
            fn=fn,
            args=args,
            kwargs=kwargs,
            client_id=client_id,
            tier=tier,
            urgency=urgency_clamped,
        )

        await self.queue.put(operation)
        self.stats.submitted += 1
        self.stats.by_tier[tier.value] += 1

        logger.debug(
            f"Submitted operation for client {client_id} "
            f"(tier={tier.value}, urgency={urgency_clamped}, priority={priority})"
        )

    async def start(self) -> None:
        """Start the scheduler workers."""
        if self._running:
            logger.warning("Scheduler already running")
            return

        self._running = True
        self._worker_tasks = [
            asyncio.create_task(self._worker(i))
            for i in range(self.workers)
        ]
        logger.info(f"Started {self.workers} scheduler workers")

    async def stop(self, timeout: float = 10.0) -> None:
        """
        Stop the scheduler workers gracefully.

        Args:
            timeout: Maximum time to wait for workers to finish
        """
        if not self._running:
            return

        self._running = False

        # Wait for queue to be processed or timeout
        try:
            await asyncio.wait_for(self.queue.join(), timeout=timeout)
        except asyncio.TimeoutError:
            logger.warning(f"Scheduler stop timed out after {timeout}s")

        # Cancel all workers
        for task in self._worker_tasks:
            task.cancel()

        # Wait for cancellation
        await asyncio.gather(*self._worker_tasks, return_exceptions=True)
        self._worker_tasks = []

        logger.info("Scheduler stopped")

    async def _worker(self, worker_id: int) -> None:
        """
        Worker task that processes operations from the queue.

        Args:
            worker_id: Worker identifier for logging
        """
        logger.debug(f"Worker {worker_id} started")

        while self._running:
            try:
                # Get next operation (blocks if queue empty)
                operation = await asyncio.wait_for(
                    self.queue.get(),
                    timeout=1.0
                )

                # Execute operation
                try:
                    logger.debug(
                        f"Worker {worker_id} executing operation for client {operation.client_id} "
                        f"(tier={operation.tier.value}, priority={operation.priority})"
                    )

                    await operation.execute()
                    self.stats.completed += 1

                    logger.debug(
                        f"Worker {worker_id} completed operation for client {operation.client_id}"
                    )

                except Exception as e:
                    self.stats.failed += 1
                    logger.error(
                        f"Worker {worker_id} failed executing operation for "
                        f"client {operation.client_id}: {e}",
                        exc_info=True
                    )

                finally:
                    self.queue.task_done()

            except asyncio.TimeoutError:
                # Queue.get() timed out, continue loop
                continue
            except asyncio.CancelledError:
                logger.debug(f"Worker {worker_id} cancelled")
                break
            except Exception as e:
                logger.error(f"Worker {worker_id} error: {e}", exc_info=True)

        logger.debug(f"Worker {worker_id} stopped")

    def get_stats(self) -> Dict[str, Any]:
        """Get scheduler statistics."""
        stats_dict = self.stats.to_dict()
        stats_dict["queue_size"] = self.queue.qsize()
        stats_dict["workers"] = self.workers
        stats_dict["running"] = self._running
        return stats_dict

    async def wait_for_completion(self, timeout: Optional[float] = None) -> None:
        """
        Wait for all queued operations to complete.

        Args:
            timeout: Maximum time to wait (None = wait forever)
        """
        if timeout:
            await asyncio.wait_for(self.queue.join(), timeout=timeout)
        else:
            await self.queue.join()

    def is_running(self) -> bool:
        """Check if scheduler is running."""
        return self._running

    async def health_check(self) -> Dict[str, Any]:
        """
        Perform health check on scheduler.

        Returns:
            Health status information
        """
        healthy = self._running and all(not task.done() for task in self._worker_tasks)

        return {
            "healthy": healthy,
            "running": self._running,
            "workers_alive": sum(1 for task in self._worker_tasks if not task.done()),
            "workers_total": self.workers,
            "queue_size": self.queue.qsize(),
        }
