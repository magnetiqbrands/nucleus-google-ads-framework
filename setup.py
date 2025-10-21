"""Setup script for Nucleus Google Ads Automation API."""

from setuptools import setup, find_packages

setup(
    name="nucleus-google-ads-framework",
    version="0.1.0",
    description="Multi-client Google Ads automation API",
    packages=find_packages(exclude=["tests", "tests.*"]),
    python_requires=">=3.11",
    install_requires=[
        "fastapi>=0.109.0",
        "uvicorn[standard]>=0.27.0",
        "google-ads>=25.0.0",
        "redis>=5.0.1",
        "asyncpg>=0.29.0",
        "tenacity>=8.2.3",
        "pydantic>=2.5.0",
        "pydantic-settings>=2.1.0",
        "python-dotenv>=1.0.0",
        "cryptography>=41.0.7",
        "pyjwt[crypto]>=2.8.0",
        "python-multipart>=0.0.6",
    ],
)
