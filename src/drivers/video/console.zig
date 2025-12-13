const interface = @import("interface.zig");
const font_mod = @import("font.zig");
const font_types = @import("font/types.zig");
const psf = @import("font/psf.zig");
const ansi = @import("ansi.zig");
const sync = @import("sync");
const hal = @import("hal");

const MAX_COLS = 200;
const HISTORY_ROWS = 2000;

// Static buffer to avoid stack overflow (400KB BSS)
var history_buffer: [HISTORY_ROWS][MAX_COLS]u8 = undefined;

// Static pixel buffer for rendering to avoid kernel stack overflow
var static_pixel_buf: [32 * 32]u32 = undefined;

// Global lock protects the global history_buffer
// This is correct because history_buffer is global, not per-instance
var history_lock: sync.Spinlock = .{};

// Current visual state for a cell
const CellAttribute = packed struct(u8) {
    fg: u3,
    bg: u3,
    bold: bool,
    inverse: bool,
};

// Default Font wrapper
const default_font = font_types.Font{
    .width = font_mod.width,
    .height = font_mod.height,
    .bytes_per_glyph = 8,
    .data = @as([]const u8, @ptrCast(&font_mod.bitmap)),
};

pub const Console = struct {
    device: interface.GraphicsDevice,
    
    // Terminal State
    cursor_x: u32 = 0,
    cursor_y: u32 = 0,
    fg_color: u32 = 0xFFFFFFFF,
    bg_color: u32 = 0x00000000,
    rows: u32,
    cols: u32,
    
    // Current Styles
    curr_fg: ansi.Color,
    curr_bg: ansi.Color,
    curr_bold: bool,
    curr_inverse: bool,
    
    cursor_visible: bool,

    // History Buffer
    history: *[HISTORY_ROWS][MAX_COLS]u8,
    history_head: usize = 0,
    write_head: usize = 0,
    view_offset: usize = 0,

    current_font: font_types.Font,
    
    parser: ansi.Parser = .{},
    
    // Dirty rect tracking
    dirty_rect: ?interface.Rect = null,

    pub fn init(device: interface.GraphicsDevice) Console {
        const mode = device.getMode();
        _ = psf; 
        var self = Console{
            .device = device,
            .cursor_x = 0,
            .cursor_y = 0,
            .rows = mode.height / default_font.height,
            .cols = mode.width / default_font.width,
            .curr_fg = .white,
            .curr_bg = .black,
            .curr_bold = false,
            .curr_inverse = false,
            .cursor_visible = true, // Default on
            .history = &history_buffer,
            .write_head = 0,
            .view_offset = 0,
            .current_font = default_font,
            .dirty_rect = null,
        };
        
        if (self.cols > MAX_COLS) self.cols = MAX_COLS;
        
        self.clear();
        return self;
    }

    // Context Interface methods for ANSI Parser
    pub fn print(self: *Console, char: u8) void {
        if (self.cursor_x >= self.cols) {
            self.newline();
        }
        self.drawCharAt(char, self.cursor_x);
        self.cursor_x += 1;
    }
    
    pub fn execute(self: *Console, char: u8) void {
        switch (char) {
            '\n' => self.newline(),
            '\r' => self.cursor_x = 0,
            '\t' => {
                 const tab_width = 4;
                 const spaces = tab_width - (self.cursor_x % tab_width);
                 for (0..spaces) |_| self.print(' ');
            },
            0x08 => { // Backspace
                if (self.cursor_x > 0) {
                    self.cursor_x -= 1;
                    self.drawCharAt(' ', self.cursor_x);
                }
            },
            else => {},
        }
    }
    
    pub fn setFg(self: *Console, color: ansi.Color) void {
        self.curr_fg = color;
    }
    
    pub fn setBg(self: *Console, color: ansi.Color) void {
        self.curr_bg = color;
    }
    
    pub fn setAttribute(self: *Console, attr: ansi.Attribute) void {
        switch (attr) {
            .reset => {
                self.curr_fg = .white;
                self.curr_bg = .black;
                self.curr_bold = false;
                self.curr_inverse = false;
            },
            .bold => self.curr_bold = true,
            .inverse => self.curr_inverse = true,
            .normal => self.curr_bold = false,
            .no_inverse => self.curr_inverse = false,
        }
    }
    
    pub fn setCursorVisible(self: *Console, visible: bool) void {
        self.cursor_visible = visible;
        // Ideally trigger a redraw of the cursor, but we don't draw a persistent cursor block yet.
    }

    pub fn clear(self: *Console) void {
        // Can be called from Parser (Context)
        // Lock is already held by write() usually.
        // Be careful if called internally vs externally.
        // If called from parser via write, lock is held.
        // If clear called directly public?
        
        const mode = self.device.getMode();
        // Use current BG color
        self.device.fillRect(0, 0, mode.width, mode.height, interface.Color{ .r=0, .g=0, .b=0 }); 
        self.cursor_x = 0;
        self.cursor_y = 0;
        self.write_head = 0;
        self.view_offset = 0;
        
        // Clear history
        for (0..HISTORY_ROWS) |y| {
            for (0..self.cols) |x| {
                self.history[y][x] = ' ';
            }
        }
        
        self.markDirty(0, 0, mode.width, mode.height);
        self.device.present(self.dirty_rect);
    }

    pub fn write(self: *Console, text: []const u8) void {
        const irq_state = hal.cpu.disableInterruptsSaveFlags();
        defer hal.cpu.restoreInterrupts(irq_state);
        
        const held = history_lock.acquire();
        defer held.release();
        
        self.dirty_rect = null;

        for (text) |c| {
            self.parser.process(c, self);
        }
        
        self.device.present(self.dirty_rect);
    }

    pub fn scrollUp(self: *Console, lines: usize) void {
        const irq_state = hal.cpu.disableInterruptsSaveFlags();
        defer hal.cpu.restoreInterrupts(irq_state);
        
        const held = history_lock.acquire();
        defer held.release();
        
        if (self.view_offset + lines < HISTORY_ROWS) {
            self.view_offset += lines;
            self.redraw();
            self.device.present(null); // Full redraw implies full present
        }
    }

    pub fn scrollDown(self: *Console, lines: usize) void {
        const irq_state = hal.cpu.disableInterruptsSaveFlags();
        defer hal.cpu.restoreInterrupts(irq_state);

        const held = history_lock.acquire();
        defer held.release();
        
        if (lines >= self.view_offset) {
            self.view_offset = 0;
        } else {
            self.view_offset -= lines;
        }
        self.redraw();
        self.device.present(null); // Full redraw implies full present
    }
    
    fn redraw(self: *Console) void {
        const mode = self.device.getMode();
        // Fill properly with black or current bg? Black is safer for clearing.
        // Fill properly with black or current bg? Black is safer for clearing.
        self.device.fillRect(0, 0, mode.width, mode.height, .{ .r=0, .g=0, .b=0 }); 
        
        const screen_rows = self.rows;
        
        var r: u32 = 0;
        while (r < screen_rows) : (r += 1) {
            const back_shift = self.view_offset + (screen_rows - 1 - r);
            const history_idx = (self.write_head + HISTORY_ROWS * 2 - back_shift) % HISTORY_ROWS;
            
            const line = &self.history[history_idx];
            
            var c: u32 = 0;
            while (c < self.cols) : (c += 1) {
                const char = line[c];
                if (char != ' ') {
                    // When redrawing from history, we lose formatting because we didn't save it.
                    // We assume default white/black for history.
                    // This is the limitation mentioned.
                    self.drawCharAtRaw(char, c, r, .white, .black, false, false);
                }
            }
        }
    }
    
    fn newline(self: *Console) void {
        self.cursor_x = 0;
        self.write_head = (self.write_head + 1) % HISTORY_ROWS;
        
        for (0..self.cols) |x| {
            self.history[self.write_head][x] = ' ';
        }
        
        if (self.view_offset == 0) {
            const mode = self.device.getMode();
            const font_h = self.current_font.height;
            const scroll_height = (self.rows - 1) * font_h;
            
            self.device.copyRect(
                0, font_h,
                0, 0,
                mode.width, scroll_height
            );
            self.markDirty(0, 0, mode.width, scroll_height);
            
            const bottom_y = (self.rows - 1) * font_h;
            // Fill bottom with current BG?
            const bg = interface.Color{ .r=0, .g=0, .b=0 };
            self.device.fillRect(0, bottom_y, mode.width, font_h, bg);
            self.markDirty(0, bottom_y, mode.width, font_h);
        } else {
             if (self.view_offset < HISTORY_ROWS - 1) {
                 self.view_offset += 1;
             }
        }
    }
    
    fn drawCharAt(self: *Console, char: u8, cx: u32) void {
        self.history[self.write_head][cx] = char;
        
        if (self.view_offset == 0) {
            const screen_y = self.rows - 1;
            self.drawCharAtRaw(char, cx, screen_y, self.curr_fg, self.curr_bg, self.curr_bold, self.curr_inverse);
        }
    }
    
    fn drawCharAtRaw(self: *Console, char: u8, cx: u32, cy: u32, fg_enum: ansi.Color, bg_enum: ansi.Color, bold: bool, inverse: bool) void {
        const font_w = self.current_font.width;
        const font_h = self.current_font.height;
        
        const x = cx * font_w;
        const y = cy * font_h;
        
        const glyph = self.current_font.getGlyph(char);
        
        // Use static buffer protected by lock (caller holds history_lock)
        // var pixel_buf: [32 * 32]u32 = undefined; // REMOVED stack allocation
        
        if (font_w > 32 or font_h > 32) return;
        
        // Resolve colors
        // Inverse swaps FG and BG
        // Resolve colors
        // Inverse swaps FG and BG
        const effective_fg = if (inverse) bg_enum else fg_enum;
        const effective_bg = if (inverse) fg_enum else bg_enum;
        
        const fg_u32 = self.makeColorFromAnsicode(effective_fg, bold);
        const bg_u32 = self.makeColorFromAnsicode(effective_bg, false); // Bold BG usually ignored

        const stride_bytes = (font_w + 7) / 8;
        
        for (0..font_h) |row| {
           const row_start = row * stride_bytes;
           for (0..font_w) |col| {
               const byte_offset = col / 8;
               if (row_start + byte_offset < glyph.len) {
                   const byte = glyph[row_start + byte_offset];
                   const is_set = (byte & (@as(u8, 1) << @as(u3, @truncate(col % 8)))) != 0;
                   static_pixel_buf[row * font_w + col] = if (is_set) fg_u32 else bg_u32;
               } 
           }
        }
        self.device.drawBuffer(x, y, font_w, font_h, static_pixel_buf[0..(font_w*font_h)]);
        self.markDirty(x, y, font_w, font_h);
    }
    
    fn markDirty(self: *Console, x: u32, y: u32, w: u32, h: u32) void {
        if (self.dirty_rect) |*r| {
             // Union
             const min_x = if (x < r.x) x else r.x;
             const min_y = if (y < r.y) y else r.y;
             const max_x = if (x + w > r.x + r.width) x + w else r.x + r.width;
             const max_y = if (y + h > r.y + r.height) y + h else r.y + r.height;
             
             r.x = min_x;
             r.y = min_y;
             r.width = max_x - min_x;
             r.height = max_y - min_y;
        } else {
             self.dirty_rect = interface.Rect{ .x=x, .y=y, .width=w, .height=h };
        }
    }
    
    fn makeColorFromAnsicode(self: *Console, color: ansi.Color, bold: bool) u32 {
        var r: u8 = 0; var g: u8 = 0; var b: u8 = 0;
        
        // Standard ANSI Colors
        switch (color) {
            .black =>   { r=0; g=0; b=0; },
            .red =>     { r=170; g=0; b=0; },
            .green =>   { r=0; g=170; b=0; },
            .yellow =>  { r=170; g=85; b=0; }, // Brown-ish
            .blue =>    { r=0; g=0; b=170; },
            .magenta => { r=170; g=0; b=170; },
            .cyan =>    { r=0; g=170; b=170; },
            .white =>   { r=170; g=170; b=170; },
        }
        
        // Bold = Bright
        if (bold) {
             switch (color) {
                .black =>   { r=85; g=85; b=85; }, // Dark Gray
                .red =>     { r=255; g=85; b=85; },
                .green =>   { r=85; g=255; b=85; },
                .yellow =>  { r=255; g=255; b=85; },
                .blue =>    { r=85; g=85; b=255; },
                .magenta => { r=255; g=85; b=255; },
                .cyan =>    { r=85; g=255; b=255; },
                .white =>   { r=255; g=255; b=255; },
            }
        }
        
        return self.makeColor(r, g, b);
    }
    

    
    fn makeColor(self: *Console, r: u8, g: u8, b: u8) u32 {
        const mode = self.device.getMode();
        const r_val = @as(u32, r) >> @intCast(8 - mode.red_mask_size);
        const g_val = @as(u32, g) >> @intCast(8 - mode.green_mask_size);
        const b_val = @as(u32, b) >> @intCast(8 - mode.blue_mask_size);
        
        return (r_val << @intCast(mode.red_field_position)) |
               (g_val << @intCast(mode.green_field_position)) |
               (b_val << @intCast(mode.blue_field_position));
    }
};
