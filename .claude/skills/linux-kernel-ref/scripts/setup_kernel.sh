#!/bin/bash
# Linux Kernel Sparse Checkout Script
# Only clones driver-relevant directories to save space (~300-500MB vs 4GB full)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KERNEL_DIR="$SCRIPT_DIR/../kernel"

echo "=== Linux Kernel Reference Setup ==="

if [ ! -d "$KERNEL_DIR" ]; then
    echo "Cloning Linux kernel with sparse checkout..."
    echo "This will take a few minutes on first run."
    git clone --filter=blob:none --sparse https://github.com/torvalds/linux.git "$KERNEL_DIR"
else
    echo "Kernel directory exists, updating..."
fi

cd "$KERNEL_DIR"

echo "Setting up sparse checkout paths..."
git sparse-checkout set \
    drivers/gpu/drm/i915 \
    drivers/gpu/drm/amd \
    drivers/gpu/drm/nouveau \
    drivers/net/ethernet/intel \
    drivers/net/virtio \
    drivers/usb/host \
    drivers/ata \
    drivers/input \
    drivers/video/fbdev \
    drivers/virtio \
    drivers/sound \
    drivers/nvme \
    drivers/block \
    drivers/pci \
    net \
    fs \
    include/linux \
    include/uapi \
    include/net \
    include/drm \
    include/sound \
    arch/x86/include

echo "Pulling latest changes..."
git pull --ff-only 2>/dev/null || echo "Already up to date or pull failed (offline?)"

# Show stats
echo ""
echo "=== Setup Complete ==="
echo "Kernel source: $KERNEL_DIR"
echo "Git branch: $(git rev-parse --abbrev-ref HEAD)"
echo "Latest commit: $(git log -1 --format='%h %s' 2>/dev/null || echo 'unknown')"

# Calculate size
if command -v du &> /dev/null; then
    SIZE=$(du -sh "$KERNEL_DIR" 2>/dev/null | cut -f1)
    echo "Size on disk: $SIZE"
fi

echo ""
echo "Query scripts available in: $SCRIPT_DIR"
echo "  - driver_query.py     Query driver implementations"
echo "  - register_query.py   Query register definitions"
echo "  - pci_query.py        Query PCI device patterns"
echo "  - interrupt_query.py  Query interrupt handling"
echo "  - subsystem_query.py  Query subsystem architecture"
