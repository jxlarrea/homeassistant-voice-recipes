# =============================================================================
# llama-server + llama-proxy base image for DGX Spark (ARM64 / CUDA 13)
#
# Contains:
#   - llama-server (from latest llama.cpp)
#   - llama-proxy  (async logging proxy + dashboard)
#
# Build:  ./build.sh
# =============================================================================

FROM nvidia/cuda:13.0.1-devel-ubuntu24.04 AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    git cmake build-essential curl ca-certificates libcurl4-openssl-dev golang-go \
    && rm -rf /var/lib/apt/lists/*

# Build llama.cpp
RUN git clone --depth 1 https://github.com/ggml-org/llama.cpp.git /build/llama.cpp
WORKDIR /build/llama.cpp
RUN cmake -B build -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=121 \
    && ln -s /usr/local/cuda/lib64/stubs/libcuda.so /usr/lib/aarch64-linux-gnu/libcuda.so.1 \
    && cmake --build build --config Release -j 10 \
    && rm /usr/lib/aarch64-linux-gnu/libcuda.so.1

# Build llama-proxy
COPY llama-proxy/ /build/llama-proxy/
WORKDIR /build/llama-proxy
RUN CGO_ENABLED=0 go build -o /build/llama-proxy-bin .

# ── Runtime ──
FROM nvidia/cuda:13.0.1-runtime-ubuntu24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates libgomp1 libcurl4 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/llama.cpp/build/bin/llama-server /usr/local/bin/llama-server
COPY --from=builder /build/llama.cpp/build/bin/lib*.so* /usr/local/lib/
COPY --from=builder /build/llama-proxy-bin /usr/local/bin/llama-proxy
RUN ldconfig

ENTRYPOINT ["llama-server"]
CMD ["--help"]
