const std = @import("std");
const hal = @import("hal");
const user_mem = @import("user_mem");
const sound = @import("uapi").sound;
const types = @import("types.zig");
const regs = @import("regs.zig");

const port_io = hal.io;

pub fn ioctl(self: *types.Ac97, cmd: u32, arg: usize) isize {
    const user_ptr = user_mem.UserPtr.from(arg);

    switch (cmd) {
        sound.SNDCTL_DSP_SPEED => {
            const requested = user_ptr.readValue(u32) catch return -14; // EFAULT
            
            if (self.vra_supported) {
                var rate = requested;
                if (rate < 8000) rate = 8000;
                if (rate > 48000) rate = 48000;
                
                port_io.outw(self.nam_base + regs.NAM_PCM_FRONT_DAC_RATE, @truncate(rate));
                rate = port_io.inw(self.nam_base + regs.NAM_PCM_FRONT_DAC_RATE);
                self.sample_rate = rate;
            }
            
            user_ptr.writeValue(self.sample_rate) catch return -14;
            return 0;
        },
        sound.SNDCTL_DSP_STEREO => {
            const requested = user_ptr.readValue(u32) catch return -14;
            
            var new_channels: u32 = 2;
            if (requested == 0) {
                new_channels = 1;
            } else {
                new_channels = 2;
            }
            self.channels = new_channels;
            
            const result: u32 = if (self.channels == 2) 1 else 0;
            user_ptr.writeValue(result) catch return -14;
            return 0;
        },
        sound.SNDCTL_DSP_CHANNELS => {
             const requested = user_ptr.readValue(u32) catch return -14;
             if (requested == 1) self.channels = 1;
             if (requested == 2) self.channels = 2;
             user_ptr.writeValue(self.channels) catch return -14;
             return 0;
        },
        sound.SNDCTL_DSP_SETFMT => {
            const requested = user_ptr.readValue(u32) catch return -14;
            
            if (requested == sound.AFMT_U8) {
                self.format = sound.AFMT_U8;
            } else if (requested == sound.AFMT_S16_LE) {
                self.format = sound.AFMT_S16_LE;
            }
            
            user_ptr.writeValue(self.format) catch return -14;
            return 0;
        },
        sound.SNDCTL_DSP_GETOSPACE => {
            const civ = port_io.inb(self.nabm_base + regs.NABM_PO_CIV);

            if (civ >= types.BDL_ENTRY_COUNT) {
                return -5; // EIO
            }

            const current_buf = self.current_buffer;
            if (current_buf >= types.BDL_ENTRY_COUNT) {
                return -5; // EIO
            }

            const free_buffers = (civ +% types.BDL_ENTRY_COUNT -% current_buf) % types.BDL_ENTRY_COUNT;

            if (free_buffers > types.BDL_ENTRY_COUNT) {
                return -5; // EIO
            }

            const info = [4]u32{
                @intCast(free_buffers),
                types.BDL_ENTRY_COUNT,
                types.BUFFER_SIZE,
                @intCast(free_buffers * types.BUFFER_SIZE),
            };
            const bytes = std.mem.asBytes(&info);
            if (user_mem.copyToUser(arg, bytes) != 0) return -14;
            return 0;
        },
        else => return 0,
    }
}
