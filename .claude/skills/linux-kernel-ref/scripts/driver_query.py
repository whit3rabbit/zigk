#!/usr/bin/env python3
"""
Linux Kernel Driver Query Script

Query driver implementations in the Linux kernel source.

Usage:
    python driver_query.py <driver_name> [topic]
    python driver_query.py --list

Examples:
    python driver_query.py i915 init        # i915 initialization code
    python driver_query.py e1000e mmio      # e1000e MMIO access patterns
    python driver_query.py xhci pci         # xHCI PCI setup
    python driver_query.py ahci interrupt   # AHCI interrupt handling
    python driver_query.py --list           # List available drivers
"""

import os
import sys
import subprocess
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
KERNEL_DIR = SCRIPT_DIR.parent / "kernel"

# Driver location mappings
DRIVER_PATHS = {
    # GPU drivers
    "i915": "drivers/gpu/drm/i915",
    "amdgpu": "drivers/gpu/drm/amd/amdgpu",
    "nouveau": "drivers/gpu/drm/nouveau",
    "drm": "drivers/gpu/drm",

    # Network drivers
    "e1000": "drivers/net/ethernet/intel/e1000",
    "e1000e": "drivers/net/ethernet/intel/e1000e",
    "igb": "drivers/net/ethernet/intel/igb",
    "ixgbe": "drivers/net/ethernet/intel/ixgbe",

    # USB drivers
    "xhci": "drivers/usb/host",
    "ehci": "drivers/usb/host",
    "usb": "drivers/usb",

    # Storage drivers
    "ahci": "drivers/ata",
    "nvme": "drivers/nvme",
    "block": "drivers/block",

    # Audio drivers
    "hda": "drivers/sound/pci/hda",
    "ac97": "drivers/sound/pci",
    "alsa": "drivers/sound",
    "sound": "drivers/sound",

    # Input drivers
    "hid": "drivers/input",
    "evdev": "drivers/input",
    "input": "drivers/input",

    # Video/framebuffer
    "fbdev": "drivers/video/fbdev",
    "simplefb": "drivers/video/fbdev",
    "efifb": "drivers/video/fbdev",

    # Virtio
    "virtio": "drivers/virtio",
    "virtio_gpu": "drivers/gpu/drm/virtio",

    # PCI subsystem
    "pci": "drivers/pci",

    # Network stack (net/)
    "tcp": "net/ipv4",
    "udp": "net/ipv4",
    "ip": "net/ipv4",
    "ipv6": "net/ipv6",
    "socket": "net/socket.c",
    "netfilter": "net/netfilter",
    "ethernet": "net/ethernet",
    "core_net": "net/core",
    "net": "net",

    # Filesystems (fs/)
    "vfs": "fs",
    "ext4": "fs/ext4",
    "btrfs": "fs/btrfs",
    "xfs": "fs/xfs",
    "fat": "fs/fat",
    "tmpfs": "fs/shmem.c",
    "ramfs": "fs/ramfs",
    "proc": "fs/proc",
    "sysfs": "fs/sysfs",
    "devtmpfs": "fs/devtmpfs.c",
    "fs": "fs",
}

# Topic patterns to search for
TOPIC_PATTERNS = {
    "init": [
        r"static int.*_probe\s*\(",
        r"static int.*_init\s*\(",
        r"module_init\s*\(",
        r"__init\s+",
        r"pci_register_driver",
        r"platform_driver_register",
    ],
    "pci": [
        r"pci_enable_device",
        r"pci_request_regions",
        r"pci_iomap",
        r"pci_read_config",
        r"pci_write_config",
        r"pci_set_master",
        r"struct pci_driver",
        r"PCI_DEVICE\s*\(",
    ],
    "mmio": [
        r"ioread32",
        r"iowrite32",
        r"readl\s*\(",
        r"writel\s*\(",
        r"__iomem",
        r"pci_iomap",
        r"devm_ioremap",
    ],
    "interrupt": [
        r"request_irq",
        r"devm_request_irq",
        r"pci_alloc_irq_vectors",
        r"pci_enable_msi",
        r"pci_enable_msix",
        r"irqreturn_t",
        r"IRQF_SHARED",
        r"IRQ_HANDLED",
    ],
    "dma": [
        r"dma_alloc_coherent",
        r"dma_map_single",
        r"dma_unmap_single",
        r"dma_set_mask",
        r"DMA_BIT_MASK",
        r"pci_set_dma_mask",
    ],
    "register": [
        r"#define.*_REG",
        r"#define.*_OFFSET",
        r"#define.*_MASK",
        r"#define.*_SHIFT",
        r"enum.*_regs",
    ],
    "struct": [
        r"struct\s+\w+_device\s*\{",
        r"struct\s+\w+_priv\s*\{",
        r"struct\s+\w+_info\s*\{",
        r"struct\s+\w+_data\s*\{",
    ],
    "ops": [
        r"static const struct.*_ops",
        r"\.probe\s*=",
        r"\.remove\s*=",
        r"\.suspend\s*=",
        r"\.resume\s*=",
    ],
    # Network stack patterns
    "socket": [
        r"struct socket\s*\{",
        r"struct sock\s*\{",
        r"sock_create",
        r"sock_release",
        r"sock_sendmsg",
        r"sock_recvmsg",
        r"proto_ops",
    ],
    "skb": [
        r"struct sk_buff",
        r"skb_put",
        r"skb_pull",
        r"skb_reserve",
        r"alloc_skb",
        r"dev_queue_xmit",
        r"netif_rx",
    ],
    "protocol": [
        r"struct proto\s*\{",
        r"inet_add_protocol",
        r"inet_register_protosw",
        r"tcp_prot",
        r"udp_prot",
        r"raw_prot",
    ],
    "netdev": [
        r"struct net_device_ops",
        r"netdev_priv",
        r"register_netdev",
        r"alloc_etherdev",
        r"ndo_start_xmit",
        r"ndo_open",
    ],
    # Filesystem patterns
    "inode": [
        r"struct inode\s*\{",
        r"struct inode_operations",
        r"iget",
        r"iput",
        r"new_inode",
        r"inode_init_always",
    ],
    "superblock": [
        r"struct super_block",
        r"struct super_operations",
        r"mount_bdev",
        r"kill_block_super",
        r"sget",
    ],
    "file_ops": [
        r"struct file_operations",
        r"\.read\s*=",
        r"\.write\s*=",
        r"\.open\s*=",
        r"\.release\s*=",
        r"\.mmap\s*=",
        r"\.llseek\s*=",
    ],
    "dentry": [
        r"struct dentry\s*\{",
        r"struct dentry_operations",
        r"d_alloc",
        r"d_instantiate",
        r"d_lookup",
        r"dget",
        r"dput",
    ],
    "address_space": [
        r"struct address_space",
        r"struct address_space_operations",
        r"readpage",
        r"writepage",
        r"read_folio",
        r"write_begin",
        r"write_end",
    ],
    "bio": [
        r"struct bio\s*\{",
        r"bio_alloc",
        r"submit_bio",
        r"bio_add_page",
        r"bio_endio",
    ],
}


def check_kernel_dir():
    """Verify kernel source is available."""
    if not KERNEL_DIR.exists():
        print(f"Error: Kernel source not found at {KERNEL_DIR}")
        print("Run: bash scripts/setup_kernel.sh")
        sys.exit(1)


def list_drivers():
    """List available drivers and their paths."""
    print("Available drivers:\n")
    categories = {
        "GPU": ["i915", "amdgpu", "nouveau", "drm"],
        "Network Drivers": ["e1000", "e1000e", "igb", "ixgbe"],
        "Network Stack": ["tcp", "udp", "ip", "ipv6", "socket", "netfilter", "core_net", "net"],
        "USB": ["xhci", "ehci", "usb"],
        "Storage": ["ahci", "nvme", "block"],
        "Audio": ["hda", "ac97", "alsa", "sound"],
        "Input": ["hid", "evdev", "input"],
        "Video": ["fbdev", "simplefb", "efifb"],
        "Virtio": ["virtio", "virtio_gpu"],
        "PCI": ["pci"],
        "Filesystems": ["vfs", "ext4", "btrfs", "xfs", "fat", "tmpfs", "ramfs", "proc", "sysfs", "fs"],
    }

    for category, drivers in categories.items():
        print(f"{category}:")
        for drv in drivers:
            if drv in DRIVER_PATHS:
                print(f"  {drv:12} -> {DRIVER_PATHS[drv]}")
        print()

    print("Topics:")
    print("  Driver:  " + ", ".join(["init", "pci", "mmio", "interrupt", "dma", "register", "struct", "ops"]))
    print("  Network: " + ", ".join(["socket", "skb", "protocol", "netdev"]))
    print("  FS:      " + ", ".join(["inode", "superblock", "file_ops", "dentry", "address_space", "bio"]))


def search_driver(driver_name, topic=None):
    """Search driver source for patterns."""
    check_kernel_dir()

    # Find driver path
    driver_path = None
    for name, path in DRIVER_PATHS.items():
        if driver_name.lower() in name.lower():
            driver_path = KERNEL_DIR / path
            break

    if not driver_path:
        # Try direct path match
        test_path = KERNEL_DIR / "drivers" / driver_name
        if test_path.exists():
            driver_path = test_path
        else:
            print(f"Error: Unknown driver '{driver_name}'")
            print("Use --list to see available drivers")
            sys.exit(1)

    if not driver_path.exists():
        print(f"Error: Driver path not found: {driver_path}")
        print("Run: bash scripts/setup_kernel.sh")
        sys.exit(1)

    print(f"=== {driver_name.upper()} Driver ===")
    print(f"Path: {driver_path.relative_to(KERNEL_DIR)}\n")

    # Get patterns for topic
    if topic and topic in TOPIC_PATTERNS:
        patterns = TOPIC_PATTERNS[topic]
        print(f"Topic: {topic}\n")
    else:
        # Default: show probe/init functions
        patterns = TOPIC_PATTERNS["init"] + TOPIC_PATTERNS["ops"]
        if topic:
            print(f"Warning: Unknown topic '{topic}', showing init/ops\n")

    # Search using grep/ripgrep
    for pattern in patterns:
        try:
            # Try ripgrep first (faster)
            result = subprocess.run(
                ["rg", "-n", "--color=never", "-e", pattern, str(driver_path)],
                capture_output=True,
                text=True,
                timeout=30
            )
            if result.returncode == 0 and result.stdout.strip():
                print(f"--- Pattern: {pattern} ---")
                # Limit output lines
                lines = result.stdout.strip().split("\n")[:20]
                for line in lines:
                    # Make path relative
                    if str(driver_path) in line:
                        line = line.replace(str(driver_path) + "/", "")
                    print(line)
                if len(result.stdout.strip().split("\n")) > 20:
                    print(f"... ({len(result.stdout.strip().split(chr(10)))} total matches)")
                print()
        except FileNotFoundError:
            # Fall back to grep
            try:
                result = subprocess.run(
                    ["grep", "-rn", "-E", pattern, str(driver_path)],
                    capture_output=True,
                    text=True,
                    timeout=30
                )
                if result.returncode == 0 and result.stdout.strip():
                    print(f"--- Pattern: {pattern} ---")
                    lines = result.stdout.strip().split("\n")[:20]
                    for line in lines:
                        if str(driver_path) in line:
                            line = line.replace(str(driver_path) + "/", "")
                        print(line)
                    print()
            except Exception:
                pass
        except subprocess.TimeoutExpired:
            print(f"Timeout searching for {pattern}")
        except Exception as e:
            print(f"Error: {e}")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    if sys.argv[1] == "--list":
        list_drivers()
        sys.exit(0)

    driver_name = sys.argv[1]
    topic = sys.argv[2] if len(sys.argv) > 2 else None

    search_driver(driver_name, topic)


if __name__ == "__main__":
    main()
