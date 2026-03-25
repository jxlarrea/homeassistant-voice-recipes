#!/usr/bin/env bash
# =============================================================================
# build.sh — Build wyoming-xtts ARM64 image for DGX Spark
#
# Only needed for ARM64. x86/x64 uses the pre-built lmo3/wyoming-xtts image.
#
# Usage:
#   ./build.sh
# =============================================================================
set -e

IMAGE="wyoming-xtts:local"

echo "══════════════════════════════════════════════"
echo "  Building $IMAGE (ARM64)"
echo "  Base: nvcr.io/nvidia/pytorch:25.04-py3"
echo "══════════════════════════════════════════════"
echo ""
echo "Note: first run pulls the NGC base image (~8GB) and downloads"
echo "the XTTS model at container startup (~1.8GB). Be patient."
echo ""

docker build -f Dockerfile.arm64 -t "$IMAGE" .

echo ""
echo "Done! Image: $IMAGE"
echo ""
echo "Start the container:"
echo "  docker compose -f compose.arm64.yaml up"
