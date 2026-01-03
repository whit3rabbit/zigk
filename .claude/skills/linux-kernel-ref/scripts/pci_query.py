#!/usr/bin/env python3
"""
Linux Kernel PCI Device Query Script

Query PCI device IDs and driver bindings in the kernel.

Usage:
    python pci_query.py <vendor_id> [device_id]
    python pci_query.py --vendor <name>
    python pci_query.py --class <class_code>

Examples:
    python pci_query.py 8086              # All Intel devices
    python pci_query.py 8086 1916         # Specific Intel GPU
    python pci_query.py 10de              # All NVIDIA devices
    python pci_query.py 1af4              # All VirtIO devices
    python pci_query.py --vendor intel    # Search by vendor name
    python pci_query.py --class 0300      # Display controllers
"""

import os
import sys
import subprocess
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
KERNEL_DIR = SCRIPT_DIR.parent / "kernel"

# Well-known PCI vendors
VENDORS = {
    "intel": "8086",
    "nvidia": "10de",
    "amd": "1002",
    "virtio": "1af4",
    "vmware": "15ad",
    "qemu": "1234",
    "redhat": "1b36",
    "realtek": "10ec",
    "broadcom": "14e4",
}

# PCI class codes
PCI_CLASSES = {
    "0300": "VGA/Display controller",
    "0200": "Ethernet controller",
    "0106": "SATA controller",
    "0108": "NVMe controller",
    "0c03": "USB controller",
    "0403": "Audio device",
    "0604": "PCI bridge",
}


def check_kernel_dir():
    """Verify kernel source is available."""
    if not KERNEL_DIR.exists():
        print(f"Error: Kernel source not found at {KERNEL_DIR}")
        print("Run: bash scripts/setup_kernel.sh")
        sys.exit(1)


def search_pci_ids(vendor_id, device_id=None):
    """Search for PCI device ID declarations."""
    check_kernel_dir()

    vendor_upper = vendor_id.upper()
    print(f"=== PCI Vendor 0x{vendor_upper} ===")

    if vendor_id.lower() in VENDORS.values():
        vendor_name = [k for k, v in VENDORS.items() if v == vendor_id.lower()][0]
        print(f"Vendor: {vendor_name.title()}")
    print()

    # Search patterns
    patterns = [
        f"PCI_DEVICE\\s*\\(\\s*0x{vendor_upper}",
        f"PCI_DEVICE_ID.*0x{vendor_upper}",
        f"PCI_VDEVICE\\s*\\([^,]+,\\s*0x",  # Might need vendor macro
        f"{{\\s*PCI_VENDOR_ID_.*,\\s*0x{vendor_upper}",
        f"0x{vendor_upper}.*0x",  # Vendor/device pair
    ]

    if device_id:
        device_upper = device_id.upper()
        print(f"Device: 0x{device_upper}\n")
        patterns = [
            f"0x{vendor_upper}.*0x{device_upper}",
            f"PCI_DEVICE\\s*\\(\\s*0x{vendor_upper}\\s*,\\s*0x{device_upper}",
        ]

    # Search in drivers directory
    drivers_path = KERNEL_DIR / "drivers"
    if not drivers_path.exists():
        print("Error: drivers/ not found in kernel source")
        sys.exit(1)

    found = set()
    for pattern in patterns:
        try:
            result = subprocess.run(
                ["grep", "-rn", "-E", "-i", pattern, str(drivers_path)],
                capture_output=True,
                text=True,
                timeout=60
            )
            if result.returncode == 0:
                for line in result.stdout.strip().split("\n"):
                    if line and line not in found:
                        found.add(line)
        except subprocess.TimeoutExpired:
            print("Search timeout")
        except Exception as e:
            print(f"Error: {e}")

    if found:
        print(f"Found {len(found)} matches:\n")
        for line in sorted(found)[:50]:
            # Clean up path
            line = line.replace(str(drivers_path) + "/", "drivers/")
            print(line)
        if len(found) > 50:
            print(f"\n... ({len(found)} total matches)")
    else:
        print(f"No devices found for vendor 0x{vendor_upper}")

    # Also check include/linux/pci_ids.h
    pci_ids_file = KERNEL_DIR / "include" / "linux" / "pci_ids.h"
    if pci_ids_file.exists():
        print(f"\n--- Vendor definitions in pci_ids.h ---")
        try:
            result = subprocess.run(
                ["grep", "-n", "-i", vendor_upper, str(pci_ids_file)],
                capture_output=True,
                text=True,
                timeout=10
            )
            if result.returncode == 0 and result.stdout.strip():
                lines = result.stdout.strip().split("\n")[:20]
                for line in lines:
                    print(line)
        except Exception:
            pass


def search_by_class(class_code):
    """Search by PCI class code."""
    check_kernel_dir()

    print(f"=== PCI Class 0x{class_code.upper()} ===")
    if class_code.lower() in PCI_CLASSES:
        print(f"Type: {PCI_CLASSES[class_code.lower()]}")
    print()

    drivers_path = KERNEL_DIR / "drivers"

    try:
        result = subprocess.run(
            ["grep", "-rn", "-E", f"class.*0x{class_code}", str(drivers_path)],
            capture_output=True,
            text=True,
            timeout=60
        )
        if result.returncode == 0 and result.stdout.strip():
            lines = result.stdout.strip().split("\n")[:30]
            for line in lines:
                line = line.replace(str(drivers_path) + "/", "drivers/")
                print(line)
    except Exception as e:
        print(f"Error: {e}")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        print("\nKnown vendors:")
        for name, vid in VENDORS.items():
            print(f"  {name:12} -> 0x{vid}")
        print("\nKnown classes:")
        for code, desc in PCI_CLASSES.items():
            print(f"  0x{code} -> {desc}")
        sys.exit(1)

    if sys.argv[1] == "--vendor":
        if len(sys.argv) < 3:
            print("Usage: pci_query.py --vendor <name>")
            sys.exit(1)
        vendor_name = sys.argv[2].lower()
        if vendor_name in VENDORS:
            search_pci_ids(VENDORS[vendor_name])
        else:
            print(f"Unknown vendor: {vendor_name}")
            print("Known vendors: " + ", ".join(VENDORS.keys()))
            sys.exit(1)
    elif sys.argv[1] == "--class":
        if len(sys.argv) < 3:
            print("Usage: pci_query.py --class <class_code>")
            sys.exit(1)
        search_by_class(sys.argv[2])
    else:
        vendor_id = sys.argv[1]
        device_id = sys.argv[2] if len(sys.argv) > 2 else None
        search_pci_ids(vendor_id, device_id)


if __name__ == "__main__":
    main()
