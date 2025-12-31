//! Boot Logo Display
//!
//! Displays an animated "ZK" logo during kernel boot with a gradient
//! color sweep effect. The gradient travels continuously across the
//! letters from left to right.
//!
//! Colors: Cyan (#00FFFF) -> Purple (#9B59B6)

const std = @import("std");
const interface = @import("interface.zig");
const logo_font = @import("logo_font.zig");
const hal = @import("hal");

// Gradient colors
const CYAN = interface.Color{ .r = 0x00, .g = 0xFF, .b = 0xFF };
const PURPLE = interface.Color{ .r = 0x9B, .g = 0x59, .b = 0xB6 };

// Animation timing
const TARGET_FPS: u32 = 30;
const FRAME_TIME_MS: u32 = 1000 / TARGET_FPS; // ~33ms per frame
const PHASE_INCREMENT: f32 = 0.025; // Speed of gradient sweep
const FADE_STEPS: u32 = 20;
const FADE_STEP_MS: u32 = 25; // Total fade: 500ms

/// Boot logo display state
pub const BootLogo = struct {
    device: interface.GraphicsDevice,
    logo_x: u32, // Top-left X of logo (centered)
    logo_y: u32, // Top-left Y of logo (centered)
    phase: f32, // Animation phase 0.0 to 1.0
    last_frame_time: u64, // TSC at last frame
    active: bool,
    tsc_per_ms: u64, // Cached TSC frequency

    const Self = @This();

    /// Initialize the boot logo for display
    pub fn init(device: interface.GraphicsDevice) Self {
        const mode = device.getMode();

        // Center the logo on screen
        const logo_x = if (mode.width > logo_font.LOGO_WIDTH)
            (mode.width - logo_font.LOGO_WIDTH) / 2
        else
            0;

        const logo_y = if (mode.height > logo_font.LOGO_HEIGHT)
            (mode.height - logo_font.LOGO_HEIGHT) / 2
        else
            0;

        return Self{
            .device = device,
            .logo_x = logo_x,
            .logo_y = logo_y,
            .phase = 0.0,
            .last_frame_time = hal.timing.rdtsc(),
            .active = false,
            .tsc_per_ms = hal.timing.getTscFrequency() / 1000,
        };
    }

    /// Display the logo and start animation
    pub fn show(self: *Self) void {
        self.active = true;
        self.phase = 0.0;
        self.last_frame_time = hal.timing.rdtsc();

        // Clear screen to black first
        const mode = self.device.getMode();
        self.device.fillRect(0, 0, mode.width, mode.height, interface.Color{ .r = 0, .g = 0, .b = 0 });

        // Render initial frame
        self.renderFrame(1.0);
        self.device.present(null);
    }

    /// Advance animation by one tick (call periodically during boot)
    pub fn tick(self: *Self) void {
        if (!self.active) return;

        const now = hal.timing.rdtsc();
        const elapsed_tsc = now -| self.last_frame_time;

        // Check if enough time has passed for next frame
        const frame_tsc = self.tsc_per_ms * FRAME_TIME_MS;
        if (elapsed_tsc < frame_tsc) return;

        self.last_frame_time = now;

        // Advance phase (wrap around)
        self.phase += PHASE_INCREMENT;
        if (self.phase >= 1.0) {
            self.phase -= 1.0;
        }

        // Render new frame
        self.renderFrame(1.0);
        self.device.present(interface.Rect{
            .x = self.logo_x,
            .y = self.logo_y,
            .width = logo_font.LOGO_WIDTH,
            .height = logo_font.LOGO_HEIGHT,
        });
    }

    /// Fade out the logo and clear screen
    pub fn fadeOut(self: *Self) void {
        if (!self.active) return;

        var step: u32 = 0;
        while (step < FADE_STEPS) : (step += 1) {
            const brightness = 1.0 - (@as(f32, @floatFromInt(step + 1)) / @as(f32, @floatFromInt(FADE_STEPS)));
            self.renderFrame(brightness);
            self.device.present(null);
            hal.timing.delayMs(FADE_STEP_MS);
        }

        // Final clear to black
        const mode = self.device.getMode();
        self.device.fillRect(0, 0, mode.width, mode.height, interface.Color{ .r = 0, .g = 0, .b = 0 });
        self.device.present(null);

        self.active = false;
    }

    /// Immediately hide the logo without animation
    pub fn hide(self: *Self) void {
        if (!self.active) return;

        const mode = self.device.getMode();
        self.device.fillRect(0, 0, mode.width, mode.height, interface.Color{ .r = 0, .g = 0, .b = 0 });
        self.device.present(null);

        self.active = false;
    }

    /// Check if logo is currently active
    pub fn isActive(self: *const Self) bool {
        return self.active;
    }

    /// Render a single frame of the logo with given brightness (0.0-1.0)
    fn renderFrame(self: *Self, brightness: f32) void {
        var y: u32 = 0;
        while (y < logo_font.LOGO_HEIGHT) : (y += 1) {
            var x: u32 = 0;
            while (x < logo_font.LOGO_WIDTH) : (x += 1) {
                if (logo_font.isLogoPixel(x, y)) {
                    const color = self.calculateGradientColor(x, brightness);
                    self.device.putPixel(self.logo_x + x, self.logo_y + y, color);
                } else {
                    // Background pixel - draw black
                    self.device.putPixel(self.logo_x + x, self.logo_y + y, interface.Color{ .r = 0, .g = 0, .b = 0 });
                }
            }
        }
    }

    /// Calculate gradient color for a pixel at given x position
    fn calculateGradientColor(self: *const Self, pixel_x: u32, brightness: f32) interface.Color {
        // Normalize x position to 0.0-1.0 range
        const norm_x = @as(f32, @floatFromInt(pixel_x)) / @as(f32, @floatFromInt(logo_font.LOGO_WIDTH));

        // Calculate distance from current phase point (with wrap-around)
        var dist = @abs(norm_x - self.phase);
        if (dist > 0.5) {
            dist = 1.0 - dist;
        }

        // Cosine falloff for smooth gradient transition
        // At phase point: t=1.0 (purple), away from phase: t=0.0 (cyan)
        const t = 0.5 + 0.5 * @cos(dist * 2.0 * std.math.pi);

        // Interpolate between cyan and purple
        const r = interpolate(CYAN.r, PURPLE.r, t);
        const g = interpolate(CYAN.g, PURPLE.g, t);
        const b = interpolate(CYAN.b, PURPLE.b, t);

        // Apply brightness
        return interface.Color{
            .r = @intFromFloat(@as(f32, @floatFromInt(r)) * brightness),
            .g = @intFromFloat(@as(f32, @floatFromInt(g)) * brightness),
            .b = @intFromFloat(@as(f32, @floatFromInt(b)) * brightness),
        };
    }
};

/// Linear interpolation between two u8 values
fn interpolate(a: u8, b: u8, t: f32) u8 {
    const a_f = @as(f32, @floatFromInt(a));
    const b_f = @as(f32, @floatFromInt(b));
    const result = a_f + (b_f - a_f) * t;
    return @intFromFloat(@max(0.0, @min(255.0, result)));
}

// Global instance for callback access from interrupt context
pub var g_boot_logo: ?*BootLogo = null;

/// Animation tick callback for timer interrupt use
pub fn animationTickCallback() void {
    if (g_boot_logo) |logo| {
        logo.tick();
    }
}
