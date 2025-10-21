# Google Ads Automation — Simplified Launch Plan (with Admin API)

A streamlined foundation for the multi‑client Google Ads automation platform — focused on reliability, clarity, and efficient scaling.

---

## 1. Simplified Architecture Overview

**Key Simplifications**

- 2‑tier cache only → **In‑memory LRU** + **Redis**. PostgreSQL is reserved for client state and logging.
- Introduce **Quota Governor** + **Priority Scheduler** for smart quota distribution.
- Add **Admin API endpoints** to manage SLA tiers and budgets.
- Harden **error handling** and **logging discipline**.

**Hardware Baseline**\
Hostinger VPS: 8 vCPU / 32 GB RAM / 400 GB NVMe → perfectly suited.

---

## 2. Caching Simplification

```python
# cache.py — simple in-process LRU
from collections import OrderedDict

class LRUCache:
    def __init__(self, maxsize=10_000):
        self.maxsize = maxsize
        self.cache = OrderedDict()
    def get(self, key):
        value = self.cache.get(key)
        if value is not None:
            self.cache.move_to_end(key)
        return value
    def set(self, key, value):
        self.cache[key] = value
        self.cache.move_to_end(key)
        if len(self.cache) > self.maxsize:
            self.cache.popitem(last=False)
```

**Integration (simplified manager)**

```python
self.hot_cache = LRUCache(maxsize=10_000)

async def _get_cached_result(self, cache_key):
    result = self.hot_cache.get(cache_key)
    if result:
        return result
    cached = await self.redis_pool.get(f"cache:{cache_key}")
    if cached:
        data = json.loads(cached)
        self.hot_cache.set(cache_key, data)
        return data
    return None

async def _cache_result(self, cache_key, result, ttl=300):
    payload = json.dumps(result)
    self.hot_cache.set(cache_key, result)
    await self.redis_pool.setex(f"cache:{cache_key}", ttl, payload)
```

**TTL Policy**

```python
TTL_BY_SERVICE = {
  'reporting': 300,  # 5 min
  'campaign': 1800,  # 30 min
  'keyword': 900,
  'budget': 3600,    # 1 h
  'customer': 86400  # 1 d
}
```

---

## 3. Quota Governor & Priority Scheduler

**Quota Governor**

```python
# quota.py
class QuotaGovernor:
    def __init__(self, redis):
        self.redis = redis

    async def can_run(self, client_id, units, tier):
        g = int(await self.redis.get('quota:global_remaining') or 0)
        c = int(await self.redis.get(f'quota:client:{client_id}:remaining') or 0)
        if g < units or c < units:
            return False
        if tier == 'bronze' and g < 0.15 * int(await self.redis.get('quota:global_daily') or 1):
            return False
        return True

    async def charge(self, client_id, units):
        pipe = self.redis.pipeline()
        pipe.decrby('quota:global_remaining', units)
        pipe.decrby(f'quota:client:{client_id}:remaining', units)
        await pipe.execute()
```

**Priority Scheduler**

```python
import asyncio, time
SLA_WEIGHT = {'gold':3, 'silver':2, 'bronze':1}

class Op:
    def __init__(self, prio, ts, fn, args):
        self.prio, self.ts, self.fn, self.args = prio, ts, fn, args
    def __lt__(self, other):
        return (self.prio, self.ts) < (other.prio, other.ts)

class PriorityScheduler:
    def __init__(self, workers=8):
        self.q = asyncio.PriorityQueue()
        self.workers = workers
    async def submit(self, tier, urgency, fn, *args):
        base = 100 - min(urgency, 99)
        prio = base // SLA_WEIGHT[tier]
        await self.q.put(Op(prio, time.time(), fn, args))
    async def start(self):
        tasks = [asyncio.create_task(self.worker()) for _ in range(self.workers)]
        await asyncio.gather(*tasks)
    async def worker(self):
        while True:
            op = await self.q.get()
            try:
                await op.fn(*op.args)
            finally:
                self.q.task_done()
```

---

## 4. Admin API for Quota & SLA Management

**Endpoints (FastAPI)**

```python
from fastapi import FastAPI, HTTPException

app = FastAPI()

@app.post('/admin/clients/{client_id}/tier')
async def set_tier(client_id: str, tier: str):
    if tier not in ['gold','silver','bronze']:
        raise HTTPException(400, 'Invalid tier')
    await redis.set(f'client:{client_id}:tier', tier)
    return {'status': 'ok', 'client': client_id, 'tier': tier}

@app.post('/admin/quota/reset')
async def reset_quota(global_daily: int):
    await redis.set('quota:global_daily', global_daily)
    await redis.set('quota:global_remaining', global_daily)
    return {'status': 'reset', 'global_daily': global_daily}

@app.post('/admin/clients/{client_id}/quota')
async def set_client_quota(client_id: str, quota: int):
    await redis.set(f'quota:client:{client_id}:remaining', quota)
    return {'status': 'ok', 'client': client_id, 'quota': quota}

@app.get('/admin/quota/status')
async def quota_status():
    global_remaining = await redis.get('quota:global_remaining')
    return {'global_remaining': int(global_remaining or 0)}
```

---

## 5. Error Handling & Log Controls

- Use **full‑jitter backoff** with `tenacity.wait_exponential_jitter`.
- Add **Token‑bucket filter** to rate‑limit repetitive logs.
- Aggregate duplicate stack traces hourly.
- Circuit breaker: open if ≥10 429s in 60 s and success < 50%; half‑open after 60 s.

---

## 6. Resource Allocation (8vCPU / 32 GB)

| Component                 | Allocation                          | Notes                 |
| ------------------------- | ----------------------------------- | --------------------- |
| App (Uvicorn workers 6–8) | 10–12 GB                            | main FastAPI runtime  |
| Redis                     | 8 GB                                | `allkeys-lfu`, no AOF |
| PostgreSQL                | 8 GB buffers, 20 GB effective cache | optimize NVMe         |
| System reserve            | 4 GB                                | kernel, monitoring    |

---

## 7. Rollout Steps

1. Deploy simplified build → limited pilot (10 clients).
2. Load test with Locust/k6 to \~2k RPS.
3. Enable scheduler + quota logic; set SLA tiers.
4. Add monitoring alerts on quota < 20% / 429 > 1% / latency > 350 ms.
5. Gradually scale to > 200 clients.

---

## 8. Future Enhancements

- Reintroduce disk cache only if Redis hit < 80%.
- Predictive budgeting using historical usage.
- Managed Redis/Postgres for multi-VPS clusters.
- SLA-based anomaly detection for automatic tier scaling.

---

## 9. Agentic Build Plan (Claude Code + Codex)

### Team Roster (7 agents total)

- **A1 – Architect-Orchestrator (core)**
- **A2 – API & Google Ads SDK (core)**
- **A3 – Caching & Quota Governor (core)**
- **A4 – DevOps & SRE (core)**
- **A5 – QA & Test Harness (core)**
- **A6 – Security & Compliance Core (new)** → OAuth/JWT, RBAC, policy guardrails, audits
- **A7 – Identity, Secrets & Key Management (new)** → key rotation, vaulting, envelope encryption

### Operating Guardrails (all agents)

- Code must ship with unit tests (>80% on touched lines), typed hints, docstrings.
- Feature flags for risky features; canary-first rollouts.
- SLO gate: p95 < 350ms, 429 < 1%, error rate < 0.5% in canary.

---

## 10. Pre‑Seeded Backlog (Epics → Stories)

**Legend**\
Format: `[ID] Title — Owner (Story Points) — Depends on — Acceptance Criteria`

### EPIC E1 — API Core & GAQL

- [E1-S1] Minimal client wiring & health — **A2** (3) — none — Health endpoint returns OK; Google Ads client loads with MCC.
- [E1-S2] GAQL search wrapper + pagination — **A2** (5) — E1-S1 — Given a query, returns JSON list; handles page tokens; unit tests with mocks.
- [E1-S3] Mutate wrapper (campaign/ad/keyword) — **A2** (5) — E1-S1 — Supports batch ops; returns operation IDs; error mapping covered.
- [E1-S4] Error taxonomy & mapping — **A2** (3) — E1-S1 — All GoogleAdsExceptions mapped to typed errors + HTTP codes.

### EPIC E2 — Cache & Quota

- [E2-S1] In‑process LRU cache — **A3** (2) — E1-S2 — LRU hit/miss metrics exposed.
- [E2-S2] Redis cache TTL policy — **A3** (3) — E2-S1 — TTL map by service; cache keys stable; tests.
- [E2-S3] Quota Governor skeleton — **A3** (5) — E1-S4 — Global & per‑client budgets in Redis; `can_run` + `charge` paths.
- [E2-S4] Priority Scheduler — **A3** (5) — E2-S3 — SLA-weighted queue; bounded workers; fairness validated under load.
- [E2-S5] Hooks in execute path — **A2/A3** (3) — E2-S3,E2-S4 — All API ops go through Governor + Scheduler.

### EPIC E3 — Admin API

- [E3-S1] Set tier/quota endpoints — **A2** (3) — E2-S3 — Tier validation, quota reset, per‑client quota set; auth required.
- [E3-S2] Pause/resume client/tier — **A2** (3) — E3-S1 — Redis flags respected by scheduler; e2e test.
- [E3-S3] Quota status readouts — **A2** (2) — E3-S1 — Returns global remaining, top 10 consumers.

### EPIC E4 — Security Foundation (new agent A6)

- [E4-S1] JWT service-to-service hardening — **A6** (3) — E1-S1 — RS256 with rotating kid; 15‑min expiry; audience/issuer checks.
- [E4-S2] RBAC per endpoint — **A6** (5) — E3-S1 — Roles: admin, ops, viewer; policy tests; least-priv defaults.
- [E4-S3] OAuth 2.0 device/web flow integration guide — **A6** (3) — E1-S1 — Docs + sample for adding new client refresh tokens.
- [E4-S4] Audit trail schema — **A6** (3) — E1-S4 — Append-only events for admin actions; tamper-evident hash chain.

### EPIC E5 — Identity & Secrets (new agent A7)

- [E5-S1] Secret backend abstraction — **A7** (3) — E4-S1 — Interface for env/OS keyring/Vault; tests with in‑memory impl.
- [E5-S2] Key rotation jobs — **A7** (5) — E5-S1 — Rotate JWT signing key monthly; dual-publish JWKS; zero-downtime swap.
- [E5-S3] Encrypt at rest (envelope) — **A7** (5) — E5-S1 — AES-GCM for stored refresh tokens; KEK from KMS/Vault; rotation procedure.
- [E5-S4] Secrets scanning CI step — **A7** (2) — none — Blocks commits with accidental secrets; baseline exclusions.

### EPIC E6 — DevOps & SRE

- [E6-S1] Baseline infra scripts (systemd/nginx/redis/postgres) — **A4** (3) — E1-S1 — Provisioned on 8c/32G host; idempotent.
- [E6-S2] CI/CD pipeline — **A4** (5) — E1-S2,E2-S2 — Lint/tests on PR; build artifact; deploy to staging.
- [E6-S3] Observability minimal — **A4** (3) — E2-S2 — Prom metrics + logs shipping; p95/p99, cache hit, 429 rate.

### EPIC E7 — QA & Load

- [E7-S1] Test doubles for Ads SDK — **A5** (3) — E1-S2 — Mocks/golden files; determinism.
- [E7-S2] Load harness (Locust/k6) — **A5** (5) — E2-S5 — 2k RPS mix; reports stored.
- [E7-S3] Chaos: 429/5xx storms — **A5** (3) — E2-S5 — Validate backoff, logging suppression, circuit breaker.

---

## 11. Acceptance Criteria (high level)

- **Functional**: All API operations route via Governor+Scheduler; Admin API enforces RBAC; tier pauses work.
- \*\*Perf
