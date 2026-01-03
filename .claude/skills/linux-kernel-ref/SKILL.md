---
name: linux-kernel-ref
description: >
  Queryable Linux kernel source reference for driver, network stack, and
  filesystem development. Use when implementing drivers, TCP/IP networking,
  or VFS/filesystem code to reference Linux patterns for PCI, MMIO, interrupts,
  DMA, sockets, protocols, inodes, and dentries. Provides grep-like queries
  into actual kernel code.
---

# Linux Kernel Reference

Local Linux kernel source for driver, network stack, and filesystem development reference. Query scripts search the kernel source for patterns, register definitions, and implementation examples.

## Setup

First run to clone kernel source (sparse checkout, ~300-500MB):

```bash
bash scripts/setup_kernel.sh
```

## Query Scripts

| Script | Purpose | Example |
|--------|---------|---------|
| `driver_query.py` | Driver implementations | `python scripts/driver_query.py i915 init` |
| `register_query.py` | Register definitions | `python scripts/register_query.py e1000e CTRL` |
| `pci_query.py` | PCI device patterns | `python scripts/pci_query.py 8086 1916` |
| `interrupt_query.py` | IRQ/MSI handling | `python scripts/interrupt_query.py xhci msi` |
| `subsystem_query.py` | Subsystem overview | `python scripts/subsystem_query.py drm` |

## Quick Examples

### Driver Implementation Lookup

```bash
# GPU driver initialization
python scripts/driver_query.py i915 init

# Network driver MMIO access
python scripts/driver_query.py e1000e mmio

# USB controller PCI setup
python scripts/driver_query.py xhci pci

# Storage driver interrupt handling
python scripts/driver_query.py ahci interrupt

# List all available drivers
python scripts/driver_query.py --list
```

### Register Definitions

```bash
# Intel GPU registers
python scripts/register_query.py i915 GT_

# E1000e control registers
python scripts/register_query.py e1000e CTRL

# xHCI capability registers
python scripts/register_query.py xhci CAP

# Show all register-like defines
python scripts/register_query.py ahci --all
```

### PCI Device IDs

```bash
# All Intel devices
python scripts/pci_query.py 8086

# Specific device
python scripts/pci_query.py 8086 1916

# By vendor name
python scripts/pci_query.py --vendor intel

# By class code
python scripts/pci_query.py --class 0300
```

### Interrupt Patterns

```bash
# MSI-X setup
python scripts/interrupt_query.py e1000e msi

# Legacy IRQ
python scripts/interrupt_query.py ahci legacy

# Handler implementations
python scripts/interrupt_query.py xhci --handler

# Threaded IRQ
python scripts/interrupt_query.py i915 threaded
```

### Subsystem Architecture

```bash
# DRM/KMS overview
python scripts/subsystem_query.py drm

# PCI subsystem
python scripts/subsystem_query.py pci

# Network stack
python scripts/subsystem_query.py net

# VFS/filesystem
python scripts/subsystem_query.py vfs

# List subsystems
python scripts/subsystem_query.py --list
```

### Network Stack Queries

```bash
# TCP implementation
python scripts/driver_query.py tcp socket

# Socket layer patterns
python scripts/driver_query.py net socket

# sk_buff handling
python scripts/driver_query.py net skb

# Protocol registration
python scripts/driver_query.py tcp protocol

# Network device ops
python scripts/driver_query.py e1000e netdev
```

### Filesystem Queries

```bash
# VFS inode operations
python scripts/driver_query.py vfs inode

# Superblock handling
python scripts/driver_query.py ext4 superblock

# File operations
python scripts/driver_query.py ext4 file_ops

# Dentry cache
python scripts/driver_query.py vfs dentry

# Block I/O
python scripts/driver_query.py ext4 bio

# Simple reference: ramfs
python scripts/driver_query.py ramfs init
```

## Covered Drivers

**GPU**: i915 (Intel), amdgpu (AMD), nouveau (NVIDIA), VirtIO-GPU
**Network Drivers**: e1000, e1000e, igb, ixgbe (Intel Ethernet)
**Network Stack**: TCP, UDP, IP, IPv6, socket layer, netfilter
**USB**: xhci-hcd, ehci-hcd (USB host controllers)
**Storage**: ahci (SATA), nvme (NVMe), block layer
**Audio**: Intel HDA, AC97, ALSA core
**Input**: HID, evdev, input subsystem
**Video**: simplefb, efifb, vesafb (framebuffer)
**Virtio**: virtio core, virtio-gpu
**Filesystems**: VFS, ext4, btrfs, xfs, fat, tmpfs, ramfs, proc, sysfs

## When to Use

Invoke this skill when:
- Implementing a new driver and need reference patterns
- Looking up register definitions or hardware sequences
- Understanding PCI enumeration or BAR mapping
- Implementing interrupt handling (MSI-X, legacy, threaded)
- Setting up DMA buffers and mappings
- Understanding kernel subsystem architecture
- Implementing TCP/IP networking (socket layer, protocols)
- Building a filesystem (VFS, inode ops, superblock)

## Query Topics

The `driver_query.py` script supports these topics:

### Driver Topics
| Topic | What it searches |
|-------|-----------------|
| `init` | Probe functions, module_init, driver registration |
| `pci` | PCI enable, BAR mapping, config space access |
| `mmio` | ioread/iowrite, readl/writel, __iomem |
| `interrupt` | request_irq, MSI setup, IRQ handlers |
| `dma` | dma_alloc, dma_map, DMA masks |
| `register` | Register defines, offsets, masks |
| `struct` | Driver structures (device, priv, info) |
| `ops` | Operation tables (probe, remove, suspend) |

### Network Topics
| Topic | What it searches |
|-------|-----------------|
| `socket` | struct socket/sock, sock_create/release/sendmsg |
| `skb` | sk_buff, skb_put/pull/reserve, alloc_skb |
| `protocol` | struct proto, inet_add_protocol, tcp_prot |
| `netdev` | net_device_ops, register_netdev, ndo_* |

### Filesystem Topics
| Topic | What it searches |
|-------|-----------------|
| `inode` | struct inode, inode_operations, iget/iput |
| `superblock` | super_block, super_operations, mount_bdev |
| `file_ops` | file_operations, read/write/open/release |
| `dentry` | struct dentry, dentry_operations, d_alloc |
| `address_space` | address_space_operations, readpage/writepage |
| `bio` | struct bio, bio_alloc, submit_bio |

## Notes

- Kernel source is read-only reference material
- Uses sparse checkout to minimize disk usage
- Scripts use grep/ripgrep for efficient searching
- Run `setup_kernel.sh` periodically to update
