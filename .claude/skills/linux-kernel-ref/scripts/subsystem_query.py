#!/usr/bin/env python3
"""
Linux Kernel Subsystem Query Script

Query kernel subsystem architecture and patterns.

Usage:
    python subsystem_query.py <subsystem>
    python subsystem_query.py --list

Examples:
    python subsystem_query.py drm      # DRM/KMS subsystem
    python subsystem_query.py pci      # PCI subsystem
    python subsystem_query.py usb      # USB subsystem
    python subsystem_query.py block    # Block layer
"""

import os
import sys
import subprocess
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
KERNEL_DIR = SCRIPT_DIR.parent / "kernel"

# Subsystem information
SUBSYSTEMS = {
    "drm": {
        "name": "Direct Rendering Manager (DRM/KMS)",
        "paths": [
            "drivers/gpu/drm",
            "include/drm",
            "include/uapi/drm",
        ],
        "key_files": [
            "include/drm/drm_device.h",
            "include/drm/drm_driver.h",
            "include/drm/drm_crtc.h",
            "include/drm/drm_framebuffer.h",
        ],
        "key_structs": [
            "struct drm_device",
            "struct drm_driver",
            "struct drm_crtc",
            "struct drm_encoder",
            "struct drm_connector",
            "struct drm_framebuffer",
        ],
    },
    "pci": {
        "name": "PCI Subsystem",
        "paths": [
            "drivers/pci",
            "include/linux/pci.h",
            "include/uapi/linux/pci_regs.h",
        ],
        "key_files": [
            "include/linux/pci.h",
            "include/uapi/linux/pci_regs.h",
            "drivers/pci/pci-driver.c",
        ],
        "key_structs": [
            "struct pci_dev",
            "struct pci_driver",
            "struct pci_device_id",
            "struct pci_bus",
        ],
    },
    "usb": {
        "name": "USB Subsystem",
        "paths": [
            "drivers/usb",
            "include/linux/usb.h",
            "include/uapi/linux/usb",
        ],
        "key_files": [
            "include/linux/usb.h",
            "include/linux/usb/hcd.h",
            "drivers/usb/host/xhci.h",
        ],
        "key_structs": [
            "struct usb_device",
            "struct usb_driver",
            "struct usb_hcd",
            "struct xhci_hcd",
        ],
    },
    "block": {
        "name": "Block Layer",
        "paths": [
            "drivers/block",
            "include/linux/blk-mq.h",
            "include/linux/genhd.h",
        ],
        "key_files": [
            "include/linux/blk-mq.h",
            "include/linux/blkdev.h",
        ],
        "key_structs": [
            "struct block_device",
            "struct request_queue",
            "struct blk_mq_ops",
            "struct gendisk",
        ],
    },
    "nvme": {
        "name": "NVMe Subsystem",
        "paths": [
            "drivers/nvme",
            "include/linux/nvme.h",
        ],
        "key_files": [
            "include/linux/nvme.h",
            "drivers/nvme/host/nvme.h",
            "drivers/nvme/host/pci.c",
        ],
        "key_structs": [
            "struct nvme_dev",
            "struct nvme_ctrl",
            "struct nvme_queue",
            "struct nvme_command",
        ],
    },
    "input": {
        "name": "Input Subsystem",
        "paths": [
            "drivers/input",
            "include/linux/input.h",
            "include/uapi/linux/input.h",
        ],
        "key_files": [
            "include/linux/input.h",
            "include/uapi/linux/input-event-codes.h",
        ],
        "key_structs": [
            "struct input_dev",
            "struct input_handler",
            "struct input_event",
        ],
    },
    "sound": {
        "name": "ALSA Sound Subsystem",
        "paths": [
            "drivers/sound",
            "include/sound",
        ],
        "key_files": [
            "include/sound/core.h",
            "include/sound/pcm.h",
            "include/sound/hdaudio.h",
        ],
        "key_structs": [
            "struct snd_card",
            "struct snd_pcm",
            "struct hdac_bus",
        ],
    },
    "netdev": {
        "name": "Network Device Drivers",
        "paths": [
            "drivers/net/ethernet",
            "include/linux/netdevice.h",
            "include/linux/etherdevice.h",
        ],
        "key_files": [
            "include/linux/netdevice.h",
            "include/linux/etherdevice.h",
        ],
        "key_structs": [
            "struct net_device",
            "struct net_device_ops",
            "struct sk_buff",
            "struct napi_struct",
        ],
    },
    "net": {
        "name": "Network Stack (TCP/IP)",
        "paths": [
            "net",
            "include/net",
            "include/linux/socket.h",
        ],
        "key_files": [
            "net/socket.c",
            "net/ipv4/tcp.c",
            "net/ipv4/udp.c",
            "net/ipv4/ip_input.c",
            "net/core/sock.c",
            "include/net/sock.h",
            "include/linux/socket.h",
        ],
        "key_structs": [
            "struct socket",
            "struct sock",
            "struct proto",
            "struct proto_ops",
            "struct inet_sock",
            "struct tcp_sock",
            "struct sk_buff",
        ],
    },
    "tcp": {
        "name": "TCP Protocol",
        "paths": [
            "net/ipv4",
            "include/net/tcp.h",
        ],
        "key_files": [
            "net/ipv4/tcp.c",
            "net/ipv4/tcp_input.c",
            "net/ipv4/tcp_output.c",
            "net/ipv4/tcp_ipv4.c",
            "include/net/tcp.h",
            "include/linux/tcp.h",
        ],
        "key_structs": [
            "struct tcp_sock",
            "struct tcp_skb_cb",
            "struct tcp_congestion_ops",
            "struct inet_connection_sock",
        ],
    },
    "socket": {
        "name": "Socket Layer",
        "paths": [
            "net/socket.c",
            "net/core",
            "include/linux/socket.h",
        ],
        "key_files": [
            "net/socket.c",
            "net/core/sock.c",
            "include/linux/socket.h",
            "include/net/sock.h",
        ],
        "key_structs": [
            "struct socket",
            "struct sock",
            "struct proto_ops",
            "struct sockaddr",
        ],
    },
    "vfs": {
        "name": "Virtual File System",
        "paths": [
            "fs",
            "include/linux/fs.h",
        ],
        "key_files": [
            "fs/open.c",
            "fs/read_write.c",
            "fs/namei.c",
            "fs/inode.c",
            "fs/super.c",
            "fs/dcache.c",
            "include/linux/fs.h",
            "include/linux/dcache.h",
        ],
        "key_structs": [
            "struct inode",
            "struct dentry",
            "struct super_block",
            "struct file",
            "struct file_operations",
            "struct inode_operations",
            "struct super_operations",
            "struct dentry_operations",
        ],
    },
    "ext4": {
        "name": "EXT4 Filesystem",
        "paths": [
            "fs/ext4",
        ],
        "key_files": [
            "fs/ext4/ext4.h",
            "fs/ext4/super.c",
            "fs/ext4/inode.c",
            "fs/ext4/file.c",
            "fs/ext4/dir.c",
            "fs/ext4/namei.c",
        ],
        "key_structs": [
            "struct ext4_sb_info",
            "struct ext4_inode_info",
            "struct ext4_super_block",
            "struct ext4_inode",
            "struct ext4_dir_entry_2",
        ],
    },
    "ramfs": {
        "name": "RAM Filesystem (Simple FS Reference)",
        "paths": [
            "fs/ramfs",
        ],
        "key_files": [
            "fs/ramfs/inode.c",
            "fs/ramfs/file-mmu.c",
        ],
        "key_structs": [
            "struct ramfs_mount_opts",
            "struct ramfs_fs_info",
        ],
    },
}


def check_kernel_dir():
    """Verify kernel source is available."""
    if not KERNEL_DIR.exists():
        print(f"Error: Kernel source not found at {KERNEL_DIR}")
        print("Run: bash scripts/setup_kernel.sh")
        sys.exit(1)


def list_subsystems():
    """List available subsystems."""
    print("Available subsystems:\n")
    for name, info in SUBSYSTEMS.items():
        print(f"  {name:10} - {info['name']}")
    print()


def show_subsystem(subsystem_name):
    """Show subsystem information."""
    check_kernel_dir()

    if subsystem_name.lower() not in SUBSYSTEMS:
        print(f"Error: Unknown subsystem '{subsystem_name}'")
        list_subsystems()
        sys.exit(1)

    info = SUBSYSTEMS[subsystem_name.lower()]
    print(f"=== {info['name']} ===\n")

    # Show paths
    print("Source paths:")
    for path in info["paths"]:
        full_path = KERNEL_DIR / path
        exists = "OK" if full_path.exists() else "NOT FOUND"
        print(f"  {path} [{exists}]")
    print()

    # Show key files
    print("Key files:")
    for file_path in info["key_files"]:
        full_path = KERNEL_DIR / file_path
        if full_path.exists():
            # Count lines
            try:
                with open(full_path) as f:
                    lines = len(f.readlines())
                print(f"  {file_path} ({lines} lines)")
            except Exception:
                print(f"  {file_path}")
        else:
            print(f"  {file_path} [NOT FOUND]")
    print()

    # Show key structures
    print("Key structures:")
    for struct in info["key_structs"]:
        print(f"  {struct}")

    # Search for structure definitions
    print("\n--- Structure Definitions ---")
    for struct in info["key_structs"][:3]:  # Limit to first 3
        struct_name = struct.replace("struct ", "")
        for path in info["paths"]:
            full_path = KERNEL_DIR / path
            if not full_path.exists():
                continue

            try:
                result = subprocess.run(
                    ["grep", "-rn", f"^struct {struct_name} {{", str(full_path)],
                    capture_output=True,
                    text=True,
                    timeout=10
                )
                if result.returncode == 0 and result.stdout.strip():
                    lines = result.stdout.strip().split("\n")[:3]
                    for line in lines:
                        line = line.replace(str(KERNEL_DIR) + "/", "")
                        print(line)
            except Exception:
                pass

    # Show driver examples
    print(f"\n--- Example Drivers ---")
    main_path = KERNEL_DIR / info["paths"][0]
    if main_path.exists():
        try:
            # Find C files with probe functions
            result = subprocess.run(
                ["grep", "-rl", "_probe", str(main_path)],
                capture_output=True,
                text=True,
                timeout=30
            )
            if result.returncode == 0 and result.stdout.strip():
                files = result.stdout.strip().split("\n")[:10]
                for f in files:
                    f = f.replace(str(KERNEL_DIR) + "/", "")
                    print(f"  {f}")
        except Exception:
            pass


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        list_subsystems()
        sys.exit(1)

    if sys.argv[1] == "--list":
        list_subsystems()
    else:
        show_subsystem(sys.argv[1])


if __name__ == "__main__":
    main()
