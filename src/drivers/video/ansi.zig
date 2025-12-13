const std = @import("std");

pub const Color = enum(u3) {
    black = 0,
    red = 1,
    green = 2,
    yellow = 3,
    blue = 4,
    magenta = 5,
    cyan = 6,
    white = 7,
};

pub const Attribute = enum {
    reset,
    bold,
    inverse,
    normal,      // Resets bold
    no_inverse,  // Resets inverse
};

const State = enum {
    Normal,
    Esc,
    Csi,
};

pub const Parser = struct {
    state: State = .Normal,
    csi_buf: [64]u8 = undefined,
    csi_len: usize = 0,
    
    /// Process a character and invoke callback methods on the context
    /// Context must implement:
    ///   print(u8)
    ///   execute(u8)  (for \n, \r, \t, \b)
    ///   clear()
    ///   setFg(Color)
    ///   setBg(Color)
    ///   setAttribute(Attribute)
    ///   setCursorVisible(bool)
    pub fn process(self: *Parser, char: u8, context: anytype) void {
        switch (self.state) {
            .Normal => {
                if (char == 0x1B) { // ESC
                    self.state = .Esc;
                } else if (char < 0x20 or char == 0x7F) {
                    context.execute(char);
                } else {
                    context.print(char);
                }
            },
            .Esc => {
                if (char == '[') {
                    self.state = .Csi;
                    self.csi_len = 0;
                } else {
                    // Fallback: print ESC and the char
                    self.state = .Normal;
                    context.print(0x1B);
                    context.print(char);
                }
            },
            .Csi => {
                // Collect params
                if (self.csi_len < self.csi_buf.len) {
                     // Check if this is a parameter byte (0-9, ;, ?, etc)
                     if ((char >= '0' and char <= '9') or char == ';' or char == '?' or char == ' ') {
                         self.csi_buf[self.csi_len] = char;
                         self.csi_len += 1;
                         return; // Continue collecting
                     }
                }
                
                // Final command byte? (@-~)
                if (char >= 0x40 and char <= 0x7E) {
                    self.dispatchCsi(char, context);
                    self.state = .Normal;
                    return;
                }
                
                // Unexpected/Invalid, reset
                self.state = .Normal;
                context.print(char);
            }
        }
    }
    
    fn dispatchCsi(self: *Parser, cmd: u8, context: anytype) void {
        const params_str = self.csi_buf[0..self.csi_len];
        
        if (cmd == 'm') {
            // SGR - Select Graphic Rendition
            // Default to 0 (Reset) if empty
            if (self.csi_len == 0) {
                context.setAttribute(.reset);
                return;
            }
            
            var it = std.mem.splitScalar(u8, params_str, ';');
            while (it.next()) |p| {
                const param = std.fmt.parseInt(u32, p, 10) catch 0;
                
                switch (param) {
                    0 => context.setAttribute(.reset),
                    1 => context.setAttribute(.bold),
                    7 => context.setAttribute(.inverse),
                    22 => context.setAttribute(.normal), // Not bold
                    27 => context.setAttribute(.no_inverse),
                    
                    30...37 => context.setFg(@enumFromInt(param - 30)),
                    40...47 => context.setBg(@enumFromInt(param - 40)),
                    
                    else => {},
                }
            }
        } else if (cmd == 'J') {
            // Clear Screen
            // "2J" is clear entire screen. "J" or "0J" is cursor to end.
            // Simplified: treat 'J' as clear for now if param is 2 or empty?
            // Usually 2J is the standard "clear" call.
            if (std.mem.eql(u8, params_str, "2")) {
                context.clear();
            }
        } else if (cmd == 'h') {
             // ?25h -> Show Cursor
             if (std.mem.eql(u8, params_str, "?25")) {
                 context.setCursorVisible(true);
             }
        } else if (cmd == 'l') {
             // ?25l -> Hide Cursor
             if (std.mem.eql(u8, params_str, "?25")) {
                 context.setCursorVisible(false);
             }
        }
    }
};
