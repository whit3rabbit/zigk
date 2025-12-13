#!/usr/bin/env bash
# Zscapek Docker Build Helper
# Simplifies building the kernel using Docker
#
# Usage:
#   ./tools/docker-build.sh [command] [options]
#
# Commands:
#   build       Build the kernel (default)
#   iso         Build bootable ISO
#   test        Run unit tests
#   shell       Open interactive shell
#   clean       Remove build artifacts and Docker volumes
#   all         Build for all supported architectures

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Force x86_64 platform for GRUB compatibility (grub-pc-bin is x86-only)
DOCKER_PLATFORM="linux/amd64"

# Detect Apple Silicon - x86_64 emulation under Rosetta/QEMU is unreliable for Zig
IS_APPLE_SILICON=false
if [[ "$(uname -s)" == "Darwin" ]] && [[ "$(uname -m)" == "arm64" ]]; then
    IS_APPLE_SILICON=true
fi

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if Docker is available
check_docker() {
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed or not in PATH"
        exit 1
    fi

    if ! docker info &> /dev/null; then
        log_error "Docker daemon is not running"
        exit 1
    fi
}

# Build the Docker image
build_image() {
    local target="${1:-builder}"
    log_info "Building Docker image (target: $target)..."
    docker build \
        --platform "$DOCKER_PLATFORM" \
        --target "$target" \
        -t "zscapek-builder:$target" \
        "$PROJECT_ROOT"
}

# Run a command in the container
run_in_container() {
    local target="${1:-builder}"
    shift
    local cmd="$*"

    # Ensure image exists
    if ! docker image inspect "zscapek-builder:$target" &> /dev/null; then
        build_image "$target"
    fi

    log_info "Running: $cmd"
    docker run --rm \
        --platform "$DOCKER_PLATFORM" \
        -v "$PROJECT_ROOT:/workspace" \
        -w /workspace \
        "zscapek-builder:$target" \
        $cmd
}

# Commands
cmd_build() {
    run_in_container builder zig build "$@"
    log_info "Build complete: zig-out/bin/kernel.elf"
}

cmd_iso() {

    run_in_container builder zig build iso
    log_info "ISO created: zscapek.iso"
}

cmd_test() {
    run_in_container builder zig build test
}

cmd_shell() {
    log_info "Opening interactive shell..."
    docker run --rm -it \
        --platform "$DOCKER_PLATFORM" \
        -v "$PROJECT_ROOT:/workspace" \
        -w /workspace \
        "zscapek-builder:dev" \
        /bin/bash
}

cmd_clean() {
    log_info "Cleaning build artifacts..."
    rm -rf "$PROJECT_ROOT/zig-out" "$PROJECT_ROOT/zig-cache" "$PROJECT_ROOT/zscapek.iso"

    log_info "Removing Docker volumes..."
    docker compose -f "$PROJECT_ROOT/docker-compose.yml" down -v 2>/dev/null || true

    log_info "Clean complete"
}

cmd_all() {
    log_info "Building for all architectures..."

    log_info "Building x86_64..."
    run_in_container builder zig build

    # Future: Add aarch64 build when implemented
    # log_info "Building aarch64..."
    # run_in_container builder zig build -Dtarget=aarch64-freestanding

    log_info "All builds complete"
}



# Show usage
usage() {
    cat << EOF
Zscapek Docker Build Helper

Usage: $(basename "$0") [command] [options]

Commands:
    build       Build the kernel (default)
    iso         Build bootable ISO image
    test        Run unit tests
    shell       Open interactive development shell
    clean       Remove build artifacts and Docker volumes
    all         Build for all supported architectures

Options:
    -h, --help  Show this help message

Examples:
    $(basename "$0")              # Build kernel
    $(basename "$0") iso          # Build ISO
    $(basename "$0") shell        # Interactive shell
    $(basename "$0") build -Doptimize=ReleaseSafe

EOF
}

# Check for Apple Silicon and warn about emulation issues
check_apple_silicon() {
    if [[ "$IS_APPLE_SILICON" == "true" ]]; then
        log_warn "Apple Silicon detected. Docker builds use x86_64 emulation which is unreliable for Zig."
        log_warn "Recommended: Use native build instead:"
        log_warn "  1. Install GRUB: brew install x86_64-elf-grub"
        log_warn "  2. Build directly: zig build iso"
        echo ""
        read -p "Continue with Docker anyway? [y/N] " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 0
        fi
    fi
}

# Main
main() {
    check_docker
    check_apple_silicon

    local command="${1:-build}"
    shift || true

    case "$command" in
        build)
            cmd_build "$@"
            ;;
        iso)
            cmd_iso "$@"
            ;;
        test)
            cmd_test "$@"
            ;;
        shell|sh)
            cmd_shell "$@"
            ;;
        clean)
            cmd_clean "$@"
            ;;
        all)
            cmd_all "$@"
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            log_error "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
}

main "$@"
