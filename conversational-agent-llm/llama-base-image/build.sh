#!/usr/bin/env bash
# =============================================================================
# build.sh — Build/rebuild the llama-server base image from latest source
#
# All model containers use this image. Rebuild when llama.cpp updates.
#
# Usage:
#   ./build.sh          # x86_64 (default)
#   ./build.sh arm64    # ARM64 / DGX Spark
# =============================================================================
set -e

IMAGE="llama-server:latest"

if [ "$1" = "arm64" ]; then
  DOCKERFILE="Dockerfile.arm64"
  echo "══════════════════════════════════════════════"
  echo "  Building $IMAGE (ARM64) from latest llama.cpp"
  echo "══════════════════════════════════════════════"
else
  DOCKERFILE="Dockerfile"
  echo "══════════════════════════════════════════════"
  echo "  Building $IMAGE (x86_64) from latest llama.cpp"
  echo "══════════════════════════════════════════════"
fi
echo ""

docker build -f "$DOCKERFILE" -t "$IMAGE" .

echo ""
echo "Done! Image: $IMAGE"
echo ""
echo "Restart your model containers to use the new image:"
echo "  cd /opt/llama.cpp/llama-qwen-14b-q8 && docker compose up -d"
echo "  cd /opt/llama.cpp/llama-qwen3.5-9b-q8 && docker compose up -d"
echo "  etc."
