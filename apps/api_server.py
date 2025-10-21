"""
FastAPI application server for Google Ads Automation API.

Provides health checks, GAQL/mutate operations, and admin endpoints.
"""

import logging
import os
from contextlib import asynccontextmanager
from typing import Any, Dict, List, Optional

import redis.asyncio as redis
from fastapi import FastAPI, HTTPException, Depends, status
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from core.google_ads_manager import (
    GoogleAdsManager,
    create_google_ads_manager,
    GAQLRequest,
    MutateRequest,
)
from core.quota import QuotaGovernor, SLATier
from core.scheduler import PriorityScheduler
from core.cache import CacheManager
from core.errors import AdsAPIError
from security.auth import (
    init_jwt_config,
    JWTConfig,
    Role,
    TokenData,
    require_admin,
    require_ops,
    require_viewer,
    get_current_user,
    create_token,
)

# Configure logging
logging.basicConfig(
    level=os.getenv("APP_LOG_LEVEL", "INFO"),
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)


# Global state (initialized on startup)
app_state: Dict[str, Any] = {}


@asynccontextmanager
async def lifespan(app: FastAPI):
    """
    Application lifespan manager.

    Initializes and cleans up resources on startup/shutdown.
    """
    logger.info("Starting application...")

    # Initialize Redis
    redis_url = os.getenv("REDIS_URL", "redis://localhost:6379")
    redis_client = redis.from_url(redis_url, decode_responses=False)
    app_state["redis"] = redis_client
    logger.info(f"Connected to Redis: {redis_url}")

    # Initialize Quota Governor
    quota_governor = QuotaGovernor(redis_client)
    app_state["quota_governor"] = quota_governor

    # Initialize global quota if not set
    global_quota = int(os.getenv("GLOBAL_DAILY_QUOTA", "1000000"))
    await quota_governor.reset_global_quota(global_quota)
    logger.info(f"Global quota set to {global_quota}")

    # Initialize Priority Scheduler
    scheduler_workers = int(os.getenv("SCHEDULER_WORKERS", "8"))
    scheduler = PriorityScheduler(workers=scheduler_workers)
    app_state["scheduler"] = scheduler
    await scheduler.start()
    logger.info(f"Scheduler started with {scheduler_workers} workers")

    # Initialize Cache Manager
    lru_size = int(os.getenv("LRU_CACHE_SIZE", "10000"))
    cache_manager = CacheManager(redis_client, lru_maxsize=lru_size)
    app_state["cache_manager"] = cache_manager
    logger.info(f"Cache manager initialized (LRU size: {lru_size})")

    # Initialize Google Ads Manager
    use_mock = os.getenv("APP_ENV", "development") == "development"
    ads_manager = create_google_ads_manager(
        quota_governor=quota_governor,
        scheduler=scheduler,
        cache_manager=cache_manager,
        use_mock=use_mock,
    )
    app_state["ads_manager"] = ads_manager
    logger.info(f"Google Ads Manager initialized (mock={use_mock})")

    # Initialize JWT
    jwt_config = JWTConfig(
        public_key_path=os.getenv("JWT_JWKS_PUBLIC_PATH", "/tmp/jwks-public.json"),
        private_key_path=os.getenv("JWT_JWKS_PRIVATE_PATH", "/tmp/jwks-private.json"),
        audience=os.getenv("API_JWT_AUDIENCE", "ads-api"),
        issuer=os.getenv("API_JWT_ISSUER", "ads-auth"),
        expiry_minutes=int(os.getenv("JWT_EXPIRY_MINUTES", "15")),
    )
    init_jwt_config(jwt_config)
    app_state["jwt_config"] = jwt_config
    logger.info("JWT configuration initialized")

    logger.info("Application startup complete")

    yield

    # Shutdown
    logger.info("Shutting down application...")

    # Stop scheduler
    if "scheduler" in app_state:
        await app_state["scheduler"].stop()
        logger.info("Scheduler stopped")

    # Close Redis
    if "redis" in app_state:
        await app_state["redis"].close()
        logger.info("Redis connection closed")

    logger.info("Application shutdown complete")


# Create FastAPI app
app = FastAPI(
    title="Nucleus Google Ads Automation API",
    description="Multi-client Google Ads automation with quota management and priority scheduling",
    version="0.1.0",
    lifespan=lifespan,
)


# Pydantic models for requests/responses

class HealthResponse(BaseModel):
    """Health check response."""
    status: str
    version: str
    components: Dict[str, bool]


class GAQLSearchRequest(BaseModel):
    """GAQL search request."""
    query: str = Field(..., description="GAQL query string")
    client_id: str = Field(..., description="Google Ads customer ID")
    page_size: int = Field(1000, ge=1, le=10000, description="Results per page")
    urgency: int = Field(50, ge=0, le=99, description="Operation urgency")
    cache_enabled: bool = Field(True, description="Enable caching")
    service_type: str = Field("reporting", description="Service type for TTL")


class MutateOperationRequest(BaseModel):
    """Mutate operation request."""
    operations: List[Dict[str, Any]] = Field(..., description="List of operations")
    client_id: str = Field(..., description="Google Ads customer ID")
    operation_type: str = Field(..., description="Operation type (campaign, ad_group, etc.)")
    urgency: int = Field(70, ge=0, le=99, description="Operation urgency")
    validate_only: bool = Field(False, description="Validation mode")


class SetTierRequest(BaseModel):
    """Set client tier request."""
    tier: SLATier = Field(..., description="SLA tier")


class SetQuotaRequest(BaseModel):
    """Set client quota request."""
    quota: int = Field(..., ge=0, description="Quota amount")


class ResetGlobalQuotaRequest(BaseModel):
    """Reset global quota request."""
    global_daily: int = Field(..., ge=0, description="Global daily quota")


class TokenRequest(BaseModel):
    """Token creation request (dev only)."""
    user_id: str = Field(..., description="User ID")
    role: Role = Field(..., description="User role")


class ErrorResponse(BaseModel):
    """Error response."""
    category: str
    code: str
    message: str
    retryable: bool
    details: Optional[Dict[str, Any]] = None


# Exception handler for our custom errors
@app.exception_handler(AdsAPIError)
async def ads_api_error_handler(request, exc: AdsAPIError):
    """Handle AdsAPIError exceptions."""
    return JSONResponse(
        status_code=exc.error_detail.http_status,
        content=exc.error_detail.to_dict(),
    )


# Health check endpoints

@app.get("/health", response_model=HealthResponse, tags=["Health"])
async def health_check():
    """
    Health check endpoint.

    Returns overall health status and component statuses.
    """
    redis_healthy = False
    scheduler_healthy = False

    try:
        await app_state["redis"].ping()
        redis_healthy = True
    except Exception as e:
        logger.error(f"Redis health check failed: {e}")

    try:
        health_info = await app_state["scheduler"].health_check()
        scheduler_healthy = health_info["healthy"]
    except Exception as e:
        logger.error(f"Scheduler health check failed: {e}")

    overall_healthy = redis_healthy and scheduler_healthy

    return HealthResponse(
        status="healthy" if overall_healthy else "unhealthy",
        version="0.1.0",
        components={
            "redis": redis_healthy,
            "scheduler": scheduler_healthy,
        },
    )


@app.get("/health/ready", tags=["Health"])
async def readiness_check():
    """Readiness check for Kubernetes/load balancers."""
    try:
        await app_state["redis"].ping()
        scheduler_health = await app_state["scheduler"].health_check()
        if scheduler_health["healthy"]:
            return {"status": "ready"}
    except Exception:
        pass

    raise HTTPException(status_code=503, detail="Not ready")


# API operation endpoints

@app.post("/api/search", tags=["Operations"], dependencies=[Depends(require_viewer)])
async def execute_gaql_search(
    request: GAQLSearchRequest,
    token: TokenData = Depends(get_current_user),
):
    """
    Execute GAQL search query.

    Requires VIEWER role or higher.
    """
    ads_manager: GoogleAdsManager = app_state["ads_manager"]

    gaql_request = GAQLRequest(
        query=request.query,
        client_id=request.client_id,
        page_size=request.page_size,
        cache_enabled=request.cache_enabled,
        service_type=request.service_type,
    )

    result = await ads_manager.execute_gaql(gaql_request, urgency=request.urgency)

    return {
        "status": "success",
        "client_id": request.client_id,
        "results": result,
        "count": len(result),
    }


@app.post("/api/mutate", tags=["Operations"], dependencies=[Depends(require_ops)])
async def execute_mutate(
    request: MutateOperationRequest,
    token: TokenData = Depends(get_current_user),
):
    """
    Execute mutate operation (create/update/delete).

    Requires OPS role or higher.
    """
    ads_manager: GoogleAdsManager = app_state["ads_manager"]

    mutate_request = MutateRequest(
        operations=request.operations,
        client_id=request.client_id,
        operation_type=request.operation_type,
        validate_only=request.validate_only,
    )

    result = await ads_manager.execute_mutate(mutate_request, urgency=request.urgency)

    return {
        "status": "success",
        "client_id": request.client_id,
        "response": result,
        "operations_count": len(request.operations),
    }


# Admin API endpoints

@app.post("/admin/clients/{client_id}/tier", tags=["Admin"], dependencies=[Depends(require_admin)])
async def set_client_tier(client_id: str, request: SetTierRequest):
    """
    Set SLA tier for a client.

    Requires ADMIN role.
    """
    quota_governor: QuotaGovernor = app_state["quota_governor"]
    await quota_governor.set_client_tier(client_id, request.tier)

    return {
        "status": "ok",
        "client_id": client_id,
        "tier": request.tier.value,
    }


@app.post("/admin/clients/{client_id}/quota", tags=["Admin"], dependencies=[Depends(require_admin)])
async def set_client_quota(client_id: str, request: SetQuotaRequest):
    """
    Set quota for a specific client.

    Requires ADMIN role.
    """
    quota_governor: QuotaGovernor = app_state["quota_governor"]
    await quota_governor.set_client_quota(client_id, request.quota)

    return {
        "status": "ok",
        "client_id": client_id,
        "quota": request.quota,
    }


@app.post("/admin/quota/reset", tags=["Admin"], dependencies=[Depends(require_admin)])
async def reset_global_quota(request: ResetGlobalQuotaRequest):
    """
    Reset global daily quota.

    Requires ADMIN role.
    """
    quota_governor: QuotaGovernor = app_state["quota_governor"]
    await quota_governor.reset_global_quota(request.global_daily)

    return {
        "status": "reset",
        "global_daily": request.global_daily,
    }


@app.post("/admin/clients/{client_id}/pause", tags=["Admin"], dependencies=[Depends(require_admin)])
async def pause_client(client_id: str):
    """
    Pause a client (no operations allowed).

    Requires ADMIN role.
    """
    quota_governor: QuotaGovernor = app_state["quota_governor"]
    await quota_governor.pause_client(client_id)

    return {
        "status": "paused",
        "client_id": client_id,
    }


@app.post("/admin/clients/{client_id}/resume", tags=["Admin"], dependencies=[Depends(require_admin)])
async def resume_client(client_id: str):
    """
    Resume a paused client.

    Requires ADMIN role.
    """
    quota_governor: QuotaGovernor = app_state["quota_governor"]
    await quota_governor.resume_client(client_id)

    return {
        "status": "resumed",
        "client_id": client_id,
    }


@app.get("/admin/quota/status", tags=["Admin"], dependencies=[Depends(require_ops)])
async def get_quota_status():
    """
    Get current global quota status.

    Requires OPS role or higher.
    """
    quota_governor: QuotaGovernor = app_state["quota_governor"]
    status_info = await quota_governor.get_quota_status()

    return status_info


@app.get("/admin/clients/{client_id}/status", tags=["Admin"], dependencies=[Depends(require_ops)])
async def get_client_status(client_id: str):
    """
    Get status for a specific client.

    Requires OPS role or higher.
    """
    quota_governor: QuotaGovernor = app_state["quota_governor"]
    status_info = await quota_governor.get_client_quota_status(client_id)

    return status_info


@app.get("/admin/stats", tags=["Admin"], dependencies=[Depends(require_ops)])
async def get_system_stats():
    """
    Get system statistics (cache, scheduler, quota).

    Requires OPS role or higher.
    """
    cache_manager: CacheManager = app_state["cache_manager"]
    scheduler: PriorityScheduler = app_state["scheduler"]
    quota_governor: QuotaGovernor = app_state["quota_governor"]

    cache_stats = cache_manager.get_stats()
    scheduler_stats = scheduler.get_stats()
    quota_stats = await quota_governor.get_quota_status()

    return {
        "cache": cache_stats,
        "scheduler": scheduler_stats,
        "quota": quota_stats,
    }


# Development/testing endpoints (should be disabled in production)

@app.post("/dev/token", tags=["Development"])
async def create_dev_token(request: TokenRequest):
    """
    Create a JWT token for development/testing.

    WARNING: This endpoint should be disabled in production.
    """
    if os.getenv("APP_ENV") == "production":
        raise HTTPException(
            status_code=403,
            detail="Token creation endpoint disabled in production"
        )

    token = create_token(request.user_id, request.role)
    return {
        "token": token,
        "user_id": request.user_id,
        "role": request.role.value,
    }


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "api_server:app",
        host=os.getenv("APP_HOST", "0.0.0.0"),
        port=int(os.getenv("APP_PORT", "8000")),
        workers=1,  # Use 1 for development (lifespan doesn't work well with >1 in dev)
        reload=True,
    )
