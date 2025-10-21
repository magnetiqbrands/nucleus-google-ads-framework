# Multi-stage Dockerfile for Nucleus Google Ads Automation API
# Stage 1: Base image with dependencies
FROM python:3.11-slim AS base

# Set environment variables
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN useradd -m -u 1000 -s /bin/bash adsapi && \
    mkdir -p /app /run/secrets && \
    chown -R adsapi:adsapi /app /run/secrets

WORKDIR /app

# Stage 2: Dependencies
FROM base AS dependencies

# Copy dependency files
COPY --chown=adsapi:adsapi pyproject.toml setup.py ./

# Install dependencies
USER adsapi
RUN pip install --user -e .

# Stage 3: Test (optional - run tests in CI)
FROM dependencies AS test

# Copy source code for testing
COPY --chown=adsapi:adsapi . .

# Install test dependencies
RUN pip install --user -e ".[test]"

# Run tests
RUN python -m pytest tests/ -v

# Stage 4: Production
FROM base AS production

# Copy installed dependencies from dependencies stage
COPY --from=dependencies --chown=adsapi:adsapi /home/adsapi/.local /home/adsapi/.local

# Copy application code
COPY --chown=adsapi:adsapi apps/ /app/apps/
COPY --chown=adsapi:adsapi core/ /app/core/
COPY --chown=adsapi:adsapi security/ /app/security/
COPY --chown=adsapi:adsapi infra/ /app/infra/
COPY --chown=adsapi:adsapi setup.py /app/
COPY --chown=adsapi:adsapi pyproject.toml /app/

# Copy entrypoint scripts
COPY --chown=adsapi:adsapi docker/entrypoint.sh /app/docker/
COPY --chown=adsapi:adsapi docker/vault-init.sh /app/docker/
RUN chmod +x /app/docker/*.sh

# Switch to non-root user
USER adsapi

# Add user's local bin to PATH
ENV PATH=/home/adsapi/.local/bin:$PATH

# Expose port
EXPOSE 8000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD curl -f http://localhost:8000/health || exit 1

# Default entrypoint (can be overridden for Vault)
ENTRYPOINT ["/app/docker/entrypoint.sh"]

# Default command
CMD ["uvicorn", "apps.api_server:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "4"]
