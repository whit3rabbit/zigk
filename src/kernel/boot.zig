const limine = @import("limine");

// ============================================================================
// Limine Request Structures
// These are placed in .limine_requests section for bootloader discovery.
// Limine scans for magic IDs and patches response pointers at boot time.
// ============================================================================

pub export var base_revision linksection(".limine_requests") = limine.BaseRevision{ .revision = 1 };
pub export var hhdm_request linksection(".limine_requests") = limine.HhdmRequest{};
pub export var memmap_request linksection(".limine_requests") = limine.MemoryMapRequest{};
pub export var module_request linksection(".limine_requests") = limine.ModuleRequest{};
pub export var framebuffer_request linksection(".limine_requests") = limine.FramebufferRequest{};
pub export var kernel_address_request linksection(".limine_requests") = limine.KernelAddressRequest{};
pub export var rsdp_request linksection(".limine_requests") = limine.RsdpRequest{};
