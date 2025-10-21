#!/bin/bash
# Deployment script for Nucleus Google Ads API
# Handles building, pushing, and deploying the containerized application

set -euo pipefail

# Configuration
REGISTRY="${REGISTRY:-ghcr.io/magnetiqbrands}"
IMAGE_NAME="nucleus-ads-api"
TAG="${TAG:-latest}"
COMPOSE_FILE="docker-compose.yml"
VAULT_COMPOSE_FILE="docker-compose.vault.yml"
USE_VAULT="${USE_VAULT:-false}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to build Docker image
build_image() {
    log_info "Building Docker image: $REGISTRY/$IMAGE_NAME:$TAG"

    docker build \
        --target production \
        --tag "$REGISTRY/$IMAGE_NAME:$TAG" \
        --tag "$REGISTRY/$IMAGE_NAME:$(git rev-parse --short HEAD)" \
        --build-arg BUILD_DATE="$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --build-arg VCS_REF="$(git rev-parse HEAD)" \
        .

    log_info "Build complete"
}

# Function to run tests
run_tests() {
    log_info "Running tests in container"

    docker build \
        --target test \
        --tag "$IMAGE_NAME:test" \
        .

    log_info "Tests passed"
}

# Function to push image to registry
push_image() {
    log_info "Pushing image to registry: $REGISTRY/$IMAGE_NAME:$TAG"

    docker push "$REGISTRY/$IMAGE_NAME:$TAG"
    docker push "$REGISTRY/$IMAGE_NAME:$(git rev-parse --short HEAD)"

    log_info "Push complete"
}

# Function to deploy with Docker Compose
deploy_compose() {
    log_info "Deploying with Docker Compose"

    # Pull latest image
    if [[ "$TAG" != "local" ]]; then
        docker pull "$REGISTRY/$IMAGE_NAME:$TAG" || log_warn "Failed to pull image, using local"
    fi

    # Compose files to use
    COMPOSE_FILES="-f $COMPOSE_FILE"
    if [[ "$USE_VAULT" == "true" ]]; then
        COMPOSE_FILES="$COMPOSE_FILES -f $VAULT_COMPOSE_FILE"
        log_info "Using Vault integration"
    fi

    # Stop existing containers
    docker-compose $COMPOSE_FILES down

    # Start new containers
    docker-compose $COMPOSE_FILES up -d --force-recreate

    log_info "Deployment complete"
}

# Function to check health
check_health() {
    log_info "Checking application health"

    local max_attempts=30
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        if curl -sf http://localhost:8000/health > /dev/null; then
            log_info "Application is healthy"
            return 0
        fi

        log_warn "Health check attempt $attempt/$max_attempts failed, retrying..."
        sleep 2
        ((attempt++))
    done

    log_error "Application failed health check after $max_attempts attempts"
    return 1
}

# Function to show logs
show_logs() {
    log_info "Showing application logs"
    docker-compose logs -f --tail=100 api
}

# Function to rollback
rollback() {
    log_warn "Rolling back to previous version"

    # This assumes you tagged previous version
    local previous_tag="${PREVIOUS_TAG:-}"

    if [[ -z "$previous_tag" ]]; then
        log_error "No previous tag specified. Set PREVIOUS_TAG environment variable"
        exit 1
    fi

    TAG="$previous_tag" deploy_compose
}

# Main deployment workflow
main() {
    log_info "========================================="
    log_info "Nucleus Ads API Deployment"
    log_info "========================================="
    log_info "Registry: $REGISTRY"
    log_info "Image: $IMAGE_NAME:$TAG"
    log_info "Vault: $USE_VAULT"
    log_info "========================================="
    echo ""

    # Parse command
    case "${1:-deploy}" in
        build)
            build_image
            ;;
        test)
            run_tests
            ;;
        push)
            build_image
            push_image
            ;;
        deploy)
            deploy_compose
            check_health
            ;;
        full)
            run_tests
            build_image
            push_image
            deploy_compose
            check_health
            ;;
        rollback)
            rollback
            ;;
        logs)
            show_logs
            ;;
        health)
            check_health
            ;;
        *)
            echo "Usage: $0 {build|test|push|deploy|full|rollback|logs|health}"
            echo ""
            echo "Commands:"
            echo "  build     - Build Docker image only"
            echo "  test      - Run tests in container"
            echo "  push      - Build and push to registry"
            echo "  deploy    - Deploy using Docker Compose"
            echo "  full      - Test, build, push, and deploy"
            echo "  rollback  - Rollback to previous version (set PREVIOUS_TAG)"
            echo "  logs      - Show application logs"
            echo "  health    - Check application health"
            echo ""
            echo "Environment variables:"
            echo "  REGISTRY        - Docker registry (default: ghcr.io/magnetiqbrands)"
            echo "  TAG             - Image tag (default: latest)"
            echo "  USE_VAULT       - Use Vault integration (default: false)"
            echo "  PREVIOUS_TAG    - Tag for rollback"
            exit 1
            ;;
    esac
}

main "$@"
