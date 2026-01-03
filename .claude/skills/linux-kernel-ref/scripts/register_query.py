#!/usr/bin/env python3
"""
Linux Kernel Register Definition Query Script

Query register definitions and hardware constants from kernel headers.

Usage:
    python register_query.py <driver> <pattern>
    python register_query.py <driver> --all

Examples:
    python register_query.py i915 GT_           # i915 GT registers
    python register_query.py e1000e CTRL        # e1000e control registers
    python register_query.py xhci CAPLENGTH     # xHCI capability registers
    python register_query.py ahci HOST_         # AHCI host registers
"""

import os
import sys
import subprocess
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
KERNEL_DIR = SCRIPT_DIR.parent / "kernel"

# Where to find register definitions
REGISTER_PATHS = {
    "i915": [
        "drivers/gpu/drm/i915/i915_reg.h",
        "drivers/gpu/drm/i915/display/intel_display_reg_defs.h",
        "drivers/gpu/drm/i915/gt/intel_gt_regs.h",
    ],
    "e1000e": [
        "drivers/net/ethernet/intel/e1000e/defines.h",
        "drivers/net/ethernet/intel/e1000e/hw.h",
        "drivers/net/ethernet/intel/e1000e/regs.h",
    ],
    "e1000": [
        "drivers/net/ethernet/intel/e1000/e1000_hw.h",
    ],
    "xhci": [
        "drivers/usb/host/xhci.h",
        "include/linux/usb/xhci-ext-caps.h",
    ],
    "ehci": [
        "drivers/usb/host/ehci.h",
    ],
    "ahci": [
        "drivers/ata/ahci.h",
        "include/linux/libata.h",
    ],
    "nvme": [
        "include/linux/nvme.h",
        "drivers/nvme/host/nvme.h",
    ],
    "hda": [
        "include/sound/hdaudio.h",
        "include/sound/hda_register.h",
        "drivers/sound/pci/hda/hda_intel.h",
    ],
    "virtio": [
        "include/uapi/linux/virtio_config.h",
        "include/uapi/linux/virtio_ring.h",
        "include/linux/virtio.h",
    ],
    "virtio_gpu": [
        "include/uapi/linux/virtio_gpu.h",
    ],
    "pci": [
        "include/uapi/linux/pci_regs.h",
        "include/linux/pci.h",
    ],
    "drm": [
        "include/drm/drm_fourcc.h",
        "include/uapi/drm/drm_mode.h",
    ],
}


def check_kernel_dir():
    """Verify kernel source is available."""
    if not KERNEL_DIR.exists():
        print(f"Error: Kernel source not found at {KERNEL_DIR}")
        print("Run: bash scripts/setup_kernel.sh")
        sys.exit(1)


def search_registers(driver, pattern):
    """Search for register definitions."""
    check_kernel_dir()

    # Find header files
    headers = []
    driver_lower = driver.lower()

    if driver_lower in REGISTER_PATHS:
        headers = [KERNEL_DIR / p for p in REGISTER_PATHS[driver_lower]]
    else:
        # Try to find headers in driver directory
        for name, paths in REGISTER_PATHS.items():
            if driver_lower in name:
                headers = [KERNEL_DIR / p for p in paths]
                break

    if not headers:
        print(f"Error: Unknown driver '{driver}'")
        print("Known drivers: " + ", ".join(REGISTER_PATHS.keys()))
        sys.exit(1)

    print(f"=== {driver.upper()} Register Definitions ===")
    print(f"Pattern: {pattern}\n")

    found_any = False
    for header in headers:
        if not header.exists():
            continue

        try:
            result = subprocess.run(
                ["grep", "-n", "-E", f"#define.*{pattern}", str(header)],
                capture_output=True,
                text=True,
                timeout=10
            )
            if result.returncode == 0 and result.stdout.strip():
                found_any = True
                print(f"--- {header.relative_to(KERNEL_DIR)} ---")
                lines = result.stdout.strip().split("\n")
                for line in lines[:50]:  # Limit output
                    print(line)
                if len(lines) > 50:
                    print(f"... ({len(lines)} total matches)")
                print()
        except Exception as e:
            print(f"Error searching {header}: {e}")

    # Also search include/linux for common patterns
    if not found_any:
        print("No matches in driver headers, searching include/linux...")
        include_path = KERNEL_DIR / "include" / "linux"
        if include_path.exists():
            try:
                result = subprocess.run(
                    ["grep", "-rn", "-E", f"#define.*{pattern}", str(include_path)],
                    capture_output=True,
                    text=True,
                    timeout=30
                )
                if result.returncode == 0 and result.stdout.strip():
                    lines = result.stdout.strip().split("\n")[:30]
                    for line in lines:
                        line = line.replace(str(include_path) + "/", "include/linux/")
                        print(line)
            except Exception:
                pass

    if not found_any:
        print(f"No register definitions found matching '{pattern}'")


def list_all_registers(driver):
    """List all register-like definitions."""
    check_kernel_dir()

    headers = []
    if driver.lower() in REGISTER_PATHS:
        headers = [KERNEL_DIR / p for p in REGISTER_PATHS[driver.lower()]]

    if not headers:
        print(f"Error: Unknown driver '{driver}'")
        sys.exit(1)

    print(f"=== {driver.upper()} All Register Definitions ===\n")

    for header in headers:
        if not header.exists():
            continue

        try:
            result = subprocess.run(
                ["grep", "-n", "-E", r"#define\s+\w+_(REG|OFFSET|MASK|SHIFT|CTRL|STATUS|CMD)\b", str(header)],
                capture_output=True,
                text=True,
                timeout=10
            )
            if result.returncode == 0 and result.stdout.strip():
                print(f"--- {header.relative_to(KERNEL_DIR)} ---")
                lines = result.stdout.strip().split("\n")[:100]
                for line in lines:
                    print(line)
                if len(result.stdout.strip().split("\n")) > 100:
                    print(f"... (truncated, {len(result.stdout.strip().split(chr(10)))} total)")
                print()
        except Exception as e:
            print(f"Error: {e}")


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        print("\nKnown drivers: " + ", ".join(REGISTER_PATHS.keys()))
        sys.exit(1)

    driver = sys.argv[1]
    pattern = sys.argv[2]

    if pattern == "--all":
        list_all_registers(driver)
    else:
        search_registers(driver, pattern)


if __name__ == "__main__":
    main()
