# ZK Build Environment
# Multi-architecture kernel build container
#
# Usage:
#   docker build -t zk-builder .
#   docker run --rm -v $(pwd):/workspace zk-builder zig build
#
# For different architectures, set KERNEL_ARCH build arg:
#   docker build --build-arg KERNEL_ARCH=aarch64 -t zk-builder-arm .

ARG ZIG_VERSION=0.16.0-dev.1484


FROM debian:bookworm-slim AS base

# Install base dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    xz-utils \
    git \
    xorriso \
    mtools \
    grub-pc-bin \
    grub-common \
    make \
    && rm -rf /var/lib/apt/lists/*

# Download and install Zig
ARG ZIG_VERSION
ARG TARGETARCH

RUN case "${TARGETARCH}" in \
        amd64) ZIG_ARCH="x86_64" ;; \
        arm64) ZIG_ARCH="aarch64" ;; \
        *) echo "Unsupported architecture: ${TARGETARCH}" && exit 1 ;; \
    esac && \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" \
        -o /tmp/zig.tar.xz && \
    tar -xf /tmp/zig.tar.xz -C /opt && \
    mv /opt/zig-${ZIG_ARCH}-linux-${ZIG_VERSION} /opt/zig && \
    rm /tmp/zig.tar.xz

ENV PATH="/opt/zig:${PATH}"



# QEMU stage - adds emulation support for testing
FROM base AS with-qemu

RUN apt-get update && apt-get install -y --no-install-recommends \
    qemu-system-x86 \
    qemu-system-arm \
    && rm -rf /var/lib/apt/lists/*

# Final build stage
FROM base AS builder

WORKDIR /workspace

# Copy Limine files to expected location


# Default command
CMD ["zig", "build"]

# Development stage with QEMU for testing
FROM with-qemu AS dev

WORKDIR /workspace

# Copy Limine files


CMD ["zig", "build"]
