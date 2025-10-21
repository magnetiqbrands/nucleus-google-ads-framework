Google Ads Automation — Codex Quickstart

Minimal brief for agentic coders to bootstrap the project fast. Keep it short, unambiguous, and testable.

⸻

1) Project Goal

Build a multi-client Google Ads automation API with:
	•	2-tier cache (in‑proc LRU + Redis)
	•	Quota Governor (global + per-client budgets, SLA tiers)
	•	Priority Scheduler (route work by SLA/urgency)
	•	Admin API (set tiers/quotas, pause/resume)
	•	Baseline security (RS256 JWT, RBAC)

Focus on reliability, low latency, and clean failure modes. Omit extras (disk cache, DB cache) in v1.

⸻

2) Tech Stack
	•	Python 3.11, FastAPI, Uvicorn (uvloop)
	•	google-ads SDK (Python)
	•	Redis (cache + quota state)
	•	PostgreSQL (state + logs only)
	•	pytest for tests

⸻

3) Repo Layout

/ads-api
  /apps
    api_server.py            # FastAPI app (routes, DI, startup)
  /core
    google_ads_manager.py    # execute_api_operation + GAQL/mutate wrappers
    quota.py                 # QuotaGovernor
    scheduler.py             # PriorityScheduler
    cache.py                 # LRUCache
    errors.py                # Typed errors + mapping
  /security
    auth.py                  # JWT verify (RS256), RBAC decorators
    jwks.py                  # JWKS publish/rotate (stub)
    audit.py                 # Admin action audit (append-only)
    secrets.py               # Secrets abstraction (env for v1)
  /infra
    redis.conf               # minimal
    postgres.sql             # tables: clients, api_logs, audit
    systemd.service          # optional
    nginx.conf               # optional
  /tests
    test_gaql.py
    test_cache.py
    test_quota.py
    test_scheduler.py
    test_auth.py
  pyproject.toml
  Makefile
  README.md


⸻

4) Environment

# required
GOOGLE_ADS_YAML=/etc/google-ads/google-ads.yaml
JWT_JWKS_PRIVATE_PATH=/etc/ads-api/jwks-private.json
JWT_JWKS_PUBLIC_PATH=/etc/ads-api/jwks-public.json
REDIS_URL=redis://localhost:6379
DATABASE_URL=postgresql://user:pass@localhost:5432/google_ads
API_JWT_AUDIENCE=ads-api
API_JWT_ISSUER=ads-auth


⸻

5) Quickstart

python -m venv .venv && source .venv/bin/activate
pip install -U pip && pip install fastapi uvicorn[standard] google-ads redis asyncpg tenacity
uvicorn apps.api_server:app --host 0.0.0.0 --port 8000 --workers 6 --loop uvloop


⸻

6) Core Contracts (v1)

6.1 Execute path (pseudocode)

# apps/api_server.py
# Every operation must:
# 1) check quota.can_run 2) enqueue via scheduler 3) charge on success 4) cache

6.2 Admin API (minimal)

POST   /admin/quota/reset           { global_daily }
POST   /admin/clients/{id}/quota    { quota }
POST   /admin/clients/{id}/tier     { tier: gold|silver|bronze }
POST   /admin/clients/{id}/pause    {}
POST   /admin/clients/{id}/resume   {}
GET    /admin/quota/status

6.3 Auth
	•	JWT RS256, 15m expiry, aud=API_JWT_AUDIENCE, iss=API_JWT_ISSUER
	•	Roles: admin|ops|viewer via claim role

⸻

7) Acceptance Criteria (must-pass)
	•	p95 latency ≤ 350 ms at 1k RPS mixed
	•	Cache hit rate ≥ 80% for reporting
	•	429/RESOURCE_EXHAUSTED logs deduplicated (token-bucket filter) — >90% duplicates suppressed
	•	Governor can pause bronze clients when global remaining < 15%
	•	All endpoints require JWT; RBAC enforced; basic audit logs recorded
	•	Tests pass: unit + happy-path integration

⸻

8) Minimal Backlog (Do first)
	1.	GAQL search wrapper + pagination (A2)
	2.	LRU + Redis cache with TTL map (A3)
	3.	QuotaGovernor (global/per‑client) + hooks (A3)
	4.	PriorityScheduler + execute path integration (A3/A2)
	5.	Admin API endpoints (A2)
	6.	JWT verify (RS256) + RBAC decorator (A6)
	7.	Tests for the above (A5)

⸻

9) Non‑Goals (v1)
	•	Disk/NVMe cache
	•	DB-backed cache
	•	Advanced forecasting or ML
	•	Multi‑region HA

⸻

10) Notes for Codex
	•	Keep PRs small; each PR must include tests and short docs snippet.
	•	Prefer pure functions for GAQL builders and TTL policy.
	•	Mock google-ads client in tests; no real API calls.