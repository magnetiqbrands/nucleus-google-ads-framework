.PHONY: help install install-dev test test-cov lint format run clean

help:
	@echo "Available commands:"
	@echo "  make install      - Install production dependencies"
	@echo "  make install-dev  - Install all dependencies including dev tools"
	@echo "  make test         - Run tests"
	@echo "  make test-cov     - Run tests with coverage report"
	@echo "  make lint         - Run linters (ruff, mypy)"
	@echo "  make format       - Format code with black"
	@echo "  make run          - Run the API server"
	@echo "  make clean        - Clean up cache and temp files"

install:
	pip install -U pip
	pip install -e .

install-dev:
	pip install -U pip
	pip install -e ".[dev,test]"

test:
	pytest tests/ -v

test-cov:
	pytest tests/ -v --cov=. --cov-report=term-missing --cov-report=html
	@echo "Coverage report generated in htmlcov/index.html"

lint:
	ruff check .
	mypy core/ apps/ security/

format:
	black .
	ruff check --fix .

run:
	uvicorn apps.api_server:app --host 0.0.0.0 --port 8000 --workers 6 --loop uvloop --reload

run-prod:
	uvicorn apps.api_server:app --host 0.0.0.0 --port 8000 --workers 6 --loop uvloop

clean:
	find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name ".pytest_cache" -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name "*.egg-info" -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name ".mypy_cache" -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name ".ruff_cache" -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name "htmlcov" -exec rm -rf {} + 2>/dev/null || true
	find . -type f -name ".coverage" -delete 2>/dev/null || true
	find . -type f -name "*.pyc" -delete 2>/dev/null || true
