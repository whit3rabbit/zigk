# ZK Kernel - Build System
#
# This Makefile wraps the Zig build system for convenience.
# All build logic lives in build.zig; this provides short aliases.

ARCH     ?= x86_64
OPTIMIZE ?= ReleaseSafe
BOOT     ?= doom

# Build
.PHONY: build iso clean

build:
	zig build -Darch=$(ARCH) -Doptimize=$(OPTIMIZE)

iso:
	zig build iso -Darch=$(ARCH) -Doptimize=$(OPTIMIZE)

clean:
	rm -rf zig-out .zig-cache
	rm -f disk.img esp_part.img sfs.img ext2.img usb_disk.img
	rm -f *.stamp *.log *.o

# Run
.PHONY: run run-shell run-doom

run:
	zig build run -Darch=$(ARCH) -Ddefault-boot=$(BOOT)

run-shell:
	zig build run -Darch=$(ARCH) -Ddefault-boot=shell

run-doom:
	zig build run -Darch=$(ARCH) -Ddefault-boot=doom

run-nographic:
	zig build run -Darch=$(ARCH) -Ddefault-boot=shell -Dqemu-args="-nographic"

# Test
.PHONY: test test-unit test-both

test:
	ARCH=$(ARCH) ./scripts/run_tests.sh

test-unit:
	zig build test

test-both:
	RUN_BOTH=true ./scripts/run_tests.sh

# Docker
.PHONY: docker-build docker-run

docker-build:
	docker build -t zk-builder .

docker-run:
	docker run --rm -v $(shell pwd):/workspace zk-builder zig build -Darch=$(ARCH)

# Help
.PHONY: help

help:
	@echo "ZK Kernel Build System"
	@echo ""
	@echo "Usage: make [target] [ARCH=x86_64|aarch64] [BOOT=doom|shell|test_runner]"
	@echo ""
	@echo "Build:"
	@echo "  build          Build kernel (default: x86_64, ReleaseSafe)"
	@echo "  iso            Build bootable UEFI ISO"
	@echo "  clean          Remove all build artifacts"
	@echo ""
	@echo "Run:"
	@echo "  run            Run in QEMU (default boot: doom)"
	@echo "  run-shell      Run with interactive shell"
	@echo "  run-doom       Run Doom"
	@echo "  run-nographic  Run shell via serial console (no GUI)"
	@echo ""
	@echo "Test:"
	@echo "  test           Run integration tests for ARCH"
	@echo "  test-unit      Run Zig unit tests"
	@echo "  test-both      Run integration tests for both architectures"
	@echo ""
	@echo "Docker:"
	@echo "  docker-build   Build the Docker build environment"
	@echo "  docker-run     Build kernel inside Docker"
	@echo ""
	@echo "Examples:"
	@echo "  make build ARCH=aarch64"
	@echo "  make run ARCH=x86_64 BOOT=shell"
	@echo "  make test ARCH=aarch64"
