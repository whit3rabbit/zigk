//! Boot Logo Font Data
//!
//! Contains large bitmap data for "ZK" letters used in the boot logo.
//! The bitmaps are stylized for a modern, sleek appearance with thick strokes.
//!
//! Each letter is defined as a 1-bit-per-pixel bitmap where:
//!   1 = letter pixel (will be colored with gradient)
//!   0 = background (transparent)

const std = @import("std");

// Logo dimensions
pub const LOGO_WIDTH: u32 = 240; // Total width for "ZK"
pub const LOGO_HEIGHT: u32 = 96; // Height of letters
pub const Z_WIDTH: u32 = 100; // Width of 'Z'
pub const K_WIDTH: u32 = 100; // Width of 'K'
pub const SPACING: u32 = 40; // Space between letters
pub const STROKE_WIDTH: u32 = 20; // Thickness of letter strokes

// Bytes per row for each letter bitmap
pub const Z_BYTES_PER_ROW: usize = (Z_WIDTH + 7) / 8; // 13 bytes
pub const K_BYTES_PER_ROW: usize = (K_WIDTH + 7) / 8; // 13 bytes

/// Check if a pixel is set in the 'Z' letter at given coordinates
/// Uses procedural generation for clean, scalable letter shapes
pub fn isZPixel(x: u32, y: u32) bool {
    if (x >= Z_WIDTH or y >= LOGO_HEIGHT) return false;

    const stroke = STROKE_WIDTH;
    const h = LOGO_HEIGHT;
    const w = Z_WIDTH;

    // Top horizontal bar
    if (y < stroke) {
        return true;
    }

    // Bottom horizontal bar
    if (y >= h - stroke) {
        return true;
    }

    // Diagonal stroke (going from top-right to bottom-left)
    // Calculate where the diagonal should be for this y
    const y_progress = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(h));
    const diag_center_x = @as(f32, @floatFromInt(w)) * (1.0 - y_progress);
    const half_stroke = @as(f32, @floatFromInt(stroke)) / 2.0;

    const x_f = @as(f32, @floatFromInt(x));
    if (x_f >= diag_center_x - half_stroke - 5.0 and x_f <= diag_center_x + half_stroke + 5.0) {
        return true;
    }

    return false;
}

/// Check if a pixel is set in the 'K' letter at given coordinates
/// Uses procedural generation for clean, scalable letter shapes
pub fn isKPixel(x: u32, y: u32) bool {
    if (x >= K_WIDTH or y >= LOGO_HEIGHT) return false;

    const stroke = STROKE_WIDTH;
    const h = LOGO_HEIGHT;
    const half_h = h / 2;

    // Left vertical bar
    if (x < stroke) {
        return true;
    }

    // Upper diagonal (from middle-left going to top-right)
    if (y < half_h) {
        const y_from_mid = half_h - y;
        const y_progress = @as(f32, @floatFromInt(y_from_mid)) / @as(f32, @floatFromInt(half_h));
        const diag_x = stroke + @as(u32, @intFromFloat(y_progress * @as(f32, @floatFromInt(K_WIDTH - stroke))));

        if (x >= stroke and x < diag_x + stroke) {
            // Check if we're within stroke distance of the diagonal line
            const expected_x = @as(f32, @floatFromInt(stroke)) + y_progress * @as(f32, @floatFromInt(K_WIDTH - stroke));
            const x_f = @as(f32, @floatFromInt(x));
            const dist = @abs(x_f - expected_x);
            if (dist < @as(f32, @floatFromInt(stroke)) * 0.8) {
                return true;
            }
        }
    }

    // Lower diagonal (from middle-left going to bottom-right)
    if (y >= half_h) {
        const y_from_mid = y - half_h;
        const y_progress = @as(f32, @floatFromInt(y_from_mid)) / @as(f32, @floatFromInt(half_h));
        const expected_x = @as(f32, @floatFromInt(stroke)) + y_progress * @as(f32, @floatFromInt(K_WIDTH - stroke));
        const x_f = @as(f32, @floatFromInt(x));
        const dist = @abs(x_f - expected_x);
        if (dist < @as(f32, @floatFromInt(stroke)) * 0.8) {
            return true;
        }
    }

    return false;
}

/// Get the pixel value at a given position in the combined "ZK" logo
/// Returns true if the pixel should be colored (part of the letter)
pub fn isLogoPixel(x: u32, y: u32) bool {
    if (y >= LOGO_HEIGHT) return false;

    // Check if in 'Z' region
    if (x < Z_WIDTH) {
        return isZPixel(x, y);
    }

    // Check if in spacing region
    if (x < Z_WIDTH + SPACING) {
        return false;
    }

    // Check if in 'K' region
    const k_x = x - Z_WIDTH - SPACING;
    if (k_x < K_WIDTH) {
        return isKPixel(k_x, y);
    }

    return false;
}

// Compile-time test to verify letter shapes look reasonable
comptime {
    // Verify Z has pixels at expected locations
    // Top-left corner should have pixel (top bar)
    if (!isZPixel(0, 0)) @compileError("Z should have pixel at top-left");
    // Top-right corner should have pixel (top bar)
    if (!isZPixel(Z_WIDTH - 1, 0)) @compileError("Z should have pixel at top-right");
    // Bottom-left should have pixel (bottom bar)
    if (!isZPixel(0, LOGO_HEIGHT - 1)) @compileError("Z should have pixel at bottom-left");
    // Center should have pixel (diagonal)
    if (!isZPixel(Z_WIDTH / 2, LOGO_HEIGHT / 2)) @compileError("Z should have pixel at center");

    // Verify K has pixels at expected locations
    // Left edge should have pixel (vertical bar)
    if (!isKPixel(0, 0)) @compileError("K should have pixel at top-left");
    if (!isKPixel(0, LOGO_HEIGHT - 1)) @compileError("K should have pixel at bottom-left");
    if (!isKPixel(0, LOGO_HEIGHT / 2)) @compileError("K should have pixel at middle-left");
}
