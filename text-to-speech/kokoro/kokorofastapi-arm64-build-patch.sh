#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$SCRIPT_DIR/Kokoro-FastAPI"
IMAGE_NAME="kokoro-fastapi-gpu:local"

echo "=== Updating Kokoro FastAPI ==="

# Clone if not already present
if [ ! -d "$REPO_DIR" ]; then
  echo "Cloning Kokoro-FastAPI..."
  git clone https://github.com/remsky/Kokoro-FastAPI "$REPO_DIR"
fi

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
cd "$SCRIPT_DIR"
docker compose -f compose.arm64.yaml down
docker compose -f compose.arm64.yaml up -d

echo "=== Done ==="
