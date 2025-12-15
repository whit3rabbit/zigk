//! Limine Boot Protocol Integration
//!
//! This module defines the request structures used to communicate with the
//! Limine bootloader. These structures are placed in a special ELF section
//! (`.limine_requests`) where the bootloader can find them.
//!
//! During boot, Limine populates the response fields in these structures,
//! providing the kernel with essential information such as memory map,
//! framebuffer configuration, modules, and ACPI tables.

const limine = @import("limine");

// ============================================================================
// Limine Request Structures
// These are placed in .limine_requests section for bootloader discovery.
// Limine scans for magic IDs and patches response pointers at boot time.
// ============================================================================

/// Base revision request - ensures bootloader compatibility
pub export var base_revision linksection(".limine_requests") = limine.BaseRevision{ .revision = 1 };

/// HHDM (Higher Half Direct Map) request
/// Asks Limine to map all physical memory to the higher half
pub export var hhdm_request linksection(".limine_requests") = limine.HhdmRequest{};

/// Memory map request - retrieves the physical memory map
pub export var memmap_request linksection(".limine_requests") = limine.MemoryMapRequest{};

/// Module request - retrieves loaded modules (initrd, etc.)
pub export var module_request linksection(".limine_requests") = limine.ModuleRequest{};

/// Framebuffer request - retrieves graphics mode information
pub export var framebuffer_request linksection(".limine_requests") = limine.FramebufferRequest{};

/// Kernel address request - retrieves kernel physical/virtual base addresses
pub export var kernel_address_request linksection(".limine_requests") = limine.KernelAddressRequest{};

/// RSDP request - retrieves the ACPI Root System Description Pointer
pub export var rsdp_request linksection(".limine_requests") = limine.RsdpRequest{};
