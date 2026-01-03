#!/usr/bin/env python3
"""
Linux Kernel Interrupt Handling Query Script

Query interrupt handling patterns from kernel drivers.

Usage:
    python interrupt_query.py <driver> [type]
    python interrupt_query.py <driver> --handler

Types:
    msi      - MSI/MSI-X setup
    legacy   - Legacy IRQ handling
    handler  - IRQ handler functions
    threaded - Threaded IRQ handlers

Examples:
    python interrupt_query.py e1000e msi       # e1000e MSI-X setup
    python interrupt_query.py xhci handler     # xHCI interrupt handlers
    python interrupt_query.py ahci legacy      # AHCI legacy IRQ
    python interrupt_query.py i915 threaded    # i915 threaded handlers
"""

import os
import sys
import subprocess
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
KERNEL_DIR = SCRIPT_DIR.parent / "kernel"

# Import driver paths from driver_query
DRIVER_PATHS = {
    "i915": "drivers/gpu/drm/i915",
    "amdgpu": "drivers/gpu/drm/amd/amdgpu",
    "e1000e": "drivers/net/ethernet/intel/e1000e",
    "igb": "drivers/net/ethernet/intel/igb",
    "xhci": "drivers/usb/host",
    "ehci": "drivers/usb/host",
    "ahci": "drivers/ata",
    "nvme": "drivers/nvme/host",
    "hda": "drivers/sound/pci/hda",
    "virtio": "drivers/virtio",
}

# Interrupt-related patterns
IRQ_PATTERNS = {
    "msi": [
        r"pci_alloc_irq_vectors",
        r"pci_enable_msi",
        r"pci_enable_msix",
        r"pci_irq_vector\s*\(",
        r"PCI_IRQ_MSI",
        r"PCI_IRQ_MSIX",
        r"msix_entry",
        r"devm_request_irq.*pci_irq_vector",
    ],
    "legacy": [
        r"request_irq\s*\(",
        r"devm_request_irq\s*\(",
        r"IRQF_SHARED",
        r"pci_dev->irq",
        r"free_irq\s*\(",
    ],
    "handler": [
        r"irqreturn_t\s+\w+",
        r"static\s+irqreturn_t",
        r"IRQ_HANDLED",
        r"IRQ_WAKE_THREAD",
        r"IRQ_NONE",
    ],
    "threaded": [
        r"request_threaded_irq",
        r"devm_request_threaded_irq",
        r"IRQ_WAKE_THREAD",
        r"IRQF_ONESHOT",
    ],
    "tasklet": [
        r"tasklet_init",
        r"tasklet_schedule",
        r"tasklet_struct",
        r"DECLARE_TASKLET",
    ],
    "workqueue": [
        r"schedule_work",
        r"queue_work",
        r"INIT_WORK",
        r"create_workqueue",
        r"struct work_struct",
    ],
}


def check_kernel_dir():
    """Verify kernel source is available."""
    if not KERNEL_DIR.exists():
        print(f"Error: Kernel source not found at {KERNEL_DIR}")
        print("Run: bash scripts/setup_kernel.sh")
        sys.exit(1)


def find_driver_path(driver_name):
    """Find the driver directory."""
    for name, path in DRIVER_PATHS.items():
        if driver_name.lower() in name.lower():
            return KERNEL_DIR / path
    return None


def search_irq_patterns(driver_name, irq_type=None):
    """Search for interrupt handling patterns."""
    check_kernel_dir()

    driver_path = find_driver_path(driver_name)
    if not driver_path or not driver_path.exists():
        print(f"Error: Driver '{driver_name}' not found")
        print("Known drivers: " + ", ".join(DRIVER_PATHS.keys()))
        sys.exit(1)

    print(f"=== {driver_name.upper()} Interrupt Handling ===")
    print(f"Path: {driver_path.relative_to(KERNEL_DIR)}\n")

    # Determine which patterns to search
    if irq_type and irq_type in IRQ_PATTERNS:
        pattern_groups = {irq_type: IRQ_PATTERNS[irq_type]}
        print(f"Type: {irq_type}\n")
    else:
        # Show all interrupt-related patterns
        pattern_groups = IRQ_PATTERNS
        if irq_type:
            print(f"Warning: Unknown type '{irq_type}', showing all\n")

    for group_name, patterns in pattern_groups.items():
        group_found = False
        for pattern in patterns:
            try:
                result = subprocess.run(
                    ["grep", "-rn", "-E", pattern, str(driver_path)],
                    capture_output=True,
                    text=True,
                    timeout=30
                )
                if result.returncode == 0 and result.stdout.strip():
                    if not group_found:
                        print(f"--- {group_name.upper()} ---")
                        group_found = True
                    lines = result.stdout.strip().split("\n")[:15]
                    for line in lines:
                        line = line.replace(str(driver_path) + "/", "")
                        print(line)
            except subprocess.TimeoutExpired:
                pass
            except Exception as e:
                print(f"Error: {e}")

        if group_found:
            print()


def show_handler_impl(driver_name):
    """Show actual IRQ handler implementations."""
    check_kernel_dir()

    driver_path = find_driver_path(driver_name)
    if not driver_path or not driver_path.exists():
        print(f"Error: Driver '{driver_name}' not found")
        sys.exit(1)

    print(f"=== {driver_name.upper()} IRQ Handler Implementations ===\n")

    # Find handler function signatures
    try:
        result = subprocess.run(
            ["grep", "-rn", "-E", r"^static\s+irqreturn_t\s+\w+", str(driver_path)],
            capture_output=True,
            text=True,
            timeout=30
        )
        if result.returncode == 0 and result.stdout.strip():
            print("Handler functions:")
            for line in result.stdout.strip().split("\n"):
                line = line.replace(str(driver_path) + "/", "")
                print(f"  {line}")
            print()
    except Exception as e:
        print(f"Error: {e}")

    # Find where handlers are registered
    try:
        result = subprocess.run(
            ["grep", "-rn", "-E", r"request.*irq|pci_alloc_irq", str(driver_path)],
            capture_output=True,
            text=True,
            timeout=30
        )
        if result.returncode == 0 and result.stdout.strip():
            print("IRQ registration:")
            for line in result.stdout.strip().split("\n")[:20]:
                line = line.replace(str(driver_path) + "/", "")
                print(f"  {line}")
    except Exception as e:
        print(f"Error: {e}")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        print("\nKnown drivers: " + ", ".join(DRIVER_PATHS.keys()))
        print("IRQ types: " + ", ".join(IRQ_PATTERNS.keys()))
        sys.exit(1)

    driver_name = sys.argv[1]

    if len(sys.argv) > 2:
        irq_type = sys.argv[2]
        if irq_type == "--handler":
            show_handler_impl(driver_name)
        else:
            search_irq_patterns(driver_name, irq_type)
    else:
        search_irq_patterns(driver_name)


if __name__ == "__main__":
    main()
