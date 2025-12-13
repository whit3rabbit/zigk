pub const Color = struct { r: u8, g: u8, b: u8 };

pub const VideoMode = struct {
    width: u32,
    height: u32,
    pitch: u32,     // Bytes per row
    bpp: u8,        // Bits per pixel (usually 32)
    addr: u64,      // Virtual address of framebuffer
    red_mask_size: u8 = 8,
    red_field_position: u8 = 16,
    green_mask_size: u8 = 8,
    green_field_position: u8 = 8,
    blue_mask_size: u8 = 8,
    blue_field_position: u8 = 0,
};

pub const Rect = extern struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

/// Abstract interface for any video device (Software FB or GPU)
pub const GraphicsDevice = struct {
    /// Context pointer (for the specific driver instance)
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Get current mode info
        getMode: *const fn (ctx: *anyopaque) VideoMode,
        /// Draw a single pixel (Slow, used for fallback)
        putPixel: *const fn (ctx: *anyopaque, x: u32, y: u32, color: Color) void,
        /// Fill a rectangle (Hardware accelerated if possible)
        fillRect: *const fn (ctx: *anyopaque, x: u32, y: u32, w: u32, h: u32, color: Color) void,
        /// Copy a buffer of pixels to the screen (Blit)
        drawBuffer: *const fn (ctx: *anyopaque, x: u32, y: u32, w: u32, h: u32, buffer: []const u32) void,
        /// Move a region of pixels to a new location (used for scrolling)
        copyRect: *const fn (ctx: *anyopaque, src_x: u32, src_y: u32, dst_x: u32, dst_y: u32, w: u32, h: u32) void,
        /// Present the back buffer to the screen (Double Buffering)
        /// If dirty_rect is provided, only that region needs to be updated.
        present: *const fn (ctx: *anyopaque, dirty_rect: ?Rect) void,
    };
    
    // Wrapper functions
    
    pub fn getMode(self: GraphicsDevice) VideoMode {
        return self.vtable.getMode(self.ptr);
    }
    
    pub fn putPixel(self: GraphicsDevice, x: u32, y: u32, color: Color) void {
        self.vtable.putPixel(self.ptr, x, y, color);
    }

    pub fn fillRect(self: GraphicsDevice, x: u32, y: u32, w: u32, h: u32, color: Color) void {
        self.vtable.fillRect(self.ptr, x, y, w, h, color);
    }
    
    pub fn drawBuffer(self: GraphicsDevice, x: u32, y: u32, w: u32, h: u32, buffer: []const u32) void {
        self.vtable.drawBuffer(self.ptr, x, y, w, h, buffer);
    }

    pub fn copyRect(self: GraphicsDevice, src_x: u32, src_y: u32, dst_x: u32, dst_y: u32, w: u32, h: u32) void {
        self.vtable.copyRect(self.ptr, src_x, src_y, dst_x, dst_y, w, h);
    }
    
    pub fn present(self: GraphicsDevice, dirty_rect: ?Rect) void {
        self.vtable.present(self.ptr, dirty_rect);
    }
};
