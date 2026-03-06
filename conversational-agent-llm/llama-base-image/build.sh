#!/bin/bash
# =============================================================================
# build.sh — Build/rebuild the llama-server base image from latest source
#
# All model containers use this image. Rebuild when llama.cpp updates.
#
# Usage:
#   cd /opt/llama.cpp/llama-base-image
#   ./build.sh
# =============================================================================
set -e

IMAGE="llama-server:latest"

echo "══════════════════════════════════════════════"
echo "  Building $IMAGE from latest llama.cpp"
echo "══════════════════════════════════════════════"
echo ""

docker build -t "$IMAGE" .

echo ""
echo "Done! Image: $IMAGE"
echo ""
echo "Restart your model containers to use the new image:"
echo "  cd /opt/llama.cpp/llama-qwen-14b-q8 && docker compose up -d"
echo "  cd /opt/llama.cpp/llama-qwen3.5-9b-q8 && docker compose up -d"
echo "  etc."
