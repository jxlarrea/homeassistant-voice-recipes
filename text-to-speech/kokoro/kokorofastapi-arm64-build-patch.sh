#!/bin/bash
set -e

REPO_DIR="/opt/kokoro-fastapi"
IMAGE_NAME="kokoro-fastapi-gpu:local"
COMPOSE_DIR="/opt/wyoming-openai"

echo "=== Updating Kokoro FastAPI ==="

# Pull latest
cd "$REPO_DIR"
echo "Pulling latest changes..."
git pull

# Patch Dockerfile: remove --platform=$BUILDPLATFORM to enable native ARM64 build
echo "Patching Dockerfile for ARM64..."
sed 's/FROM --platform=\$BUILDPLATFORM /FROM /' docker/gpu/Dockerfile > docker/gpu/Dockerfile.arm64

# Build
echo "Building ARM64 GPU image..."
docker build -f docker/gpu/Dockerfile.arm64 -t "$IMAGE_NAME" .

# Restart
echo "Restarting containers..."
cd "$COMPOSE_DIR"
docker compose down
docker compose up -d

echo "=== Done ==="