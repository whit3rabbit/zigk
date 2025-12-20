const std = @import("std");
const uapi = @import("uapi");
const sound = uapi.sound;
const types = @import("types.zig");

/// Process audio data from user format to hardware format (S16_LE Stereo).
/// Returns number of bytes consumed from src and written to dst.
pub fn processAudio(self: *types.Ac97, dst: []u8, src: []const u8) struct { consumed: usize, written: usize } {
    var s_off: usize = 0;
    var d_off: usize = 0;
    
    // Limits
    const s_max = src.len;
    const d_max = dst.len;

    // Optimization: 1:1 Copy (Stereo S16LE -> Stereo S16LE)
    if (self.channels == 2 and self.format == sound.AFMT_S16_LE) {
        const copy_len = @min(s_max, d_max);
        // Must align to frame size (4 bytes)
        const aligned_len = copy_len & ~@as(usize, 3);
        @memcpy(dst[0..aligned_len], src[0..aligned_len]);
        return .{ .consumed = aligned_len, .written = aligned_len };
    }

    while (s_off < s_max and d_off < d_max) {
        // Determine input frame size
        const bytes_per_sample: usize = if (self.format == sound.AFMT_U8) 1 else 2;
        const input_frame_size = bytes_per_sample * self.channels;

        // Check if we have a full frame in src
        if (s_off + input_frame_size > s_max) break;
        // Check if we have space for stereo S16 frame (4 bytes) in dst
        if (d_off + 4 > d_max) break;
        
        // Read L/R samples, normalized to i16
        var left: i16 = 0;
        var right: i16 = 0;
        
        if (self.format == sound.AFMT_U8) {
             // U8 is unsigned 0..255, bias 128. 
             // Conversion to i16: (u8 - 128) * 256
             const l_val: i16 = @as(i16, src[s_off]) - 128;
             left = l_val * 256;
             
             if (self.channels == 2) {
                 const r_val: i16 = @as(i16, src[s_off+1]) - 128;
                 right = r_val * 256;
             } else {
                 right = left;
             }
        } else {
             // S16_LE
             const l_low = src[s_off];
             const l_high = src[s_off+1];
             left = @as(i16, @bitCast(@as(u16, l_low) | (@as(u16, l_high) << 8)));
             
             if (self.channels == 2) {
                 const r_low = src[s_off+2];
                 const r_high = src[s_off+3];
                 right = @as(i16, @bitCast(@as(u16, r_low) | (@as(u16, r_high) << 8)));
             } else {
                 right = left;
             }
        }
        
        // Write to DST (S16_LE Stereo)
        const u_l = @as(u16, @bitCast(left));
        dst[d_off] = @truncate(u_l);
        dst[d_off+1] = @truncate(u_l >> 8);
        
        const u_r = @as(u16, @bitCast(right));
        dst[d_off+2] = @truncate(u_r);
        dst[d_off+3] = @truncate(u_r >> 8);
        
        s_off += input_frame_size;
        d_off += 4;
    }
    return .{ .consumed = s_off, .written = d_off };
}
