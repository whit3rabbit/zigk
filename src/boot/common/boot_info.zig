
pub const MemoryType = enum(u32) {
    Reserved = 0,
    LoaderCode = 1,
    LoaderData = 2,
    BootServicesCode = 3,
    BootServicesData = 4,
    RuntimeServicesCode = 5,
    RuntimeServicesData = 6,
    Conventional = 7,
    Unusable = 8,
    ACPIReclaim = 9,
    ACPINvs = 10,
    MemoryMappedIO = 11,
    MemoryMappedIOPortSpace = 12,
    PalCode = 13,
    PersistentMemory = 14,
    KernelStack = 0x1000, // Custom type
    KernelCode = 0x1001,  // Custom type
    KernelData = 0x1002,  // Custom type
    Framebuffer = 0x1003, // Custom type
    _,
};

pub const MemoryDescriptor = extern struct {
    type: MemoryType,
    phys_start: u64,
    virt_start: u64,
    num_pages: u64,
    attribute: u64,
};

pub const FramebufferInfo = extern struct {
    address: u64,
    width: u64,
    height: u64,
    pitch: u64,
    bpp: u16,
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
};

pub const BootInfo = extern struct {
    // Memory
    memory_map: [*]MemoryDescriptor,
    memory_map_count: usize,
    descriptor_size: usize,
    
    // Video (Framebuffer)
    framebuffer: ?*FramebufferInfo,

    // ACPI
    rsdp: u64,

    // Modules (InitRD)
    initrd_addr: u64,
    initrd_size: u64,
    cmdline: ?[*:0]const u8,

    // Addressing
    hhdm_offset: u64, // Usually 0xFFFF800000000000
    kernel_phys_base: u64,
    kernel_virt_base: u64,

    // KASLR offsets (set by bootloader from entropy)
    // These add randomization to kernel memory region bases
    stack_region_offset: u64, // Random offset for kernel stack region
    mmio_region_offset: u64, // Random offset for MMIO mapping region
    heap_offset: u64, // Random offset for kernel heap
};
