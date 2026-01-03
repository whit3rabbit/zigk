//! SVGA3D Command Implementation
//!
//! Provides 3D rendering capabilities for VMware SVGA II devices.
//! Supports surface management, context creation, and basic 3D operations.

const std = @import("std");
const hw = @import("hardware.zig");
const fifo = @import("fifo.zig");
const caps = @import("caps.zig");
const types = @import("svga3d_types.zig");

/// SVGA3D context manager
pub const Svga3D = struct {
    /// FIFO manager for command submission
    fifo_mgr: *fifo.FifoManager,
    /// Device capabilities
    capabilities: caps.Capabilities,
    /// 3D hardware version
    hw_version: u32,

    /// Surface ID allocator
    next_surface_id: u32 = 1,
    /// Context ID allocator
    next_context_id: u32 = 1,
    /// Shader ID allocator
    next_shader_id: u32 = 1,

    /// Maximum surfaces supported
    max_surfaces: u32 = 256,
    /// Maximum contexts supported
    max_contexts: u32 = 16,

    const Self = @This();

    /// Initialize SVGA3D context
    pub fn init(fifo_mgr: *fifo.FifoManager, capabilities: caps.Capabilities, fifo_virt: [*]volatile u32) ?Self {
        if (!capabilities.hasSvga3d()) {
            return null;
        }

        // Read 3D hardware version from extended FIFO
        const hw_version = fifo_virt[hw.FIFO_3D_HWVERSION];

        return .{
            .fifo_mgr = fifo_mgr,
            .capabilities = capabilities,
            .hw_version = hw_version,
        };
    }

    /// Check if 3D is available
    pub fn isAvailable(self: *const Self) bool {
        return self.capabilities.hasSvga3d() and self.hw_version > 0;
    }

    /// Get 3D hardware version
    pub fn getHwVersion(self: *const Self) caps.Svga3dHwVersion {
        return caps.Svga3dHwVersion.fromRaw(self.hw_version);
    }

    // ========== Surface Management ==========

    /// Create a 2D surface for rendering
    pub fn createSurface(
        self: *Self,
        width: u32,
        height: u32,
        format: hw.SurfaceFormat,
        flags: u32,
    ) ?u32 {
        if (self.next_surface_id >= self.max_surfaces) return null;

        const sid = self.next_surface_id;
        self.next_surface_id += 1;

        // Calculate command size
        const body_size = @sizeOf(types.CmdSurfaceDefine) + @sizeOf(types.Size3D);
        const total_size = @sizeOf(types.CmdHeader) + body_size;

        const slice = self.fifo_mgr.reserve(total_size) catch return null;

        // Write header
        const header: *types.CmdHeader = @ptrCast(@alignCast(&slice[0]));
        header.id = @intFromEnum(hw.Cmd3d.SurfaceDefine);
        header.size = body_size;

        // Write surface definition
        const body_offset = @sizeOf(types.CmdHeader) / 4;
        const body: *types.CmdSurfaceDefine = @ptrCast(@alignCast(&slice[body_offset]));
        body.sid = sid;
        body.surface_flags = flags;
        body.format = format;
        body.face[0] = .{ .num_mip_levels = 1 };
        for (1..6) |i| {
            body.face[i] = .{ .num_mip_levels = 0 };
        }

        // Write mip level size
        const size_offset = body_offset + (@sizeOf(types.CmdSurfaceDefine) / 4);
        const size: *types.Size3D = @ptrCast(@alignCast(&slice[size_offset]));
        size.width = width;
        size.height = height;
        size.depth = 1;

        self.fifo_mgr.commit(total_size);
        return sid;
    }

    /// Destroy a surface
    pub fn destroySurface(self: *Self, sid: u32) bool {
        const total_size = types.totalCmdSize(types.CmdSurfaceDestroy);

        const slice = self.fifo_mgr.reserve(total_size) catch return false;

        const header: *types.CmdHeader = @ptrCast(@alignCast(&slice[0]));
        header.id = @intFromEnum(hw.Cmd3d.SurfaceDestroy);
        header.size = @sizeOf(types.CmdSurfaceDestroy);

        const body: *types.CmdSurfaceDestroy = @ptrCast(@alignCast(&slice[@sizeOf(types.CmdHeader) / 4]));
        body.sid = sid;

        self.fifo_mgr.commit(total_size);
        return true;
    }

    // ========== Context Management ==========

    /// Create a rendering context
    pub fn createContext(self: *Self) ?u32 {
        if (self.next_context_id >= self.max_contexts) return null;

        const cid = self.next_context_id;
        self.next_context_id += 1;

        const total_size = types.totalCmdSize(types.CmdContextDefine);

        const slice = self.fifo_mgr.reserve(total_size) catch return null;

        const header: *types.CmdHeader = @ptrCast(@alignCast(&slice[0]));
        header.id = @intFromEnum(hw.Cmd3d.ContextDefine);
        header.size = @sizeOf(types.CmdContextDefine);

        const body: *types.CmdContextDefine = @ptrCast(@alignCast(&slice[@sizeOf(types.CmdHeader) / 4]));
        body.cid = cid;

        self.fifo_mgr.commit(total_size);
        return cid;
    }

    /// Destroy a context
    pub fn destroyContext(self: *Self, cid: u32) bool {
        const total_size = types.totalCmdSize(types.CmdContextDestroy);

        const slice = self.fifo_mgr.reserve(total_size) catch return false;

        const header: *types.CmdHeader = @ptrCast(@alignCast(&slice[0]));
        header.id = @intFromEnum(hw.Cmd3d.ContextDestroy);
        header.size = @sizeOf(types.CmdContextDestroy);

        const body: *types.CmdContextDestroy = @ptrCast(@alignCast(&slice[@sizeOf(types.CmdHeader) / 4]));
        body.cid = cid;

        self.fifo_mgr.commit(total_size);
        return true;
    }

    // ========== Render State ==========

    /// Set a render state
    pub fn setRenderState(self: *Self, cid: u32, state: types.RenderState, value: u32) bool {
        const total_size = types.totalCmdSize(types.CmdSetRenderState);

        const slice = self.fifo_mgr.reserve(total_size) catch return false;

        const header: *types.CmdHeader = @ptrCast(@alignCast(&slice[0]));
        header.id = @intFromEnum(hw.Cmd3d.SetRenderState);
        header.size = @sizeOf(types.CmdSetRenderState);

        const body: *types.CmdSetRenderState = @ptrCast(@alignCast(&slice[@sizeOf(types.CmdHeader) / 4]));
        body.cid = cid;
        body.state = @intFromEnum(state);
        body.value = value;

        self.fifo_mgr.commit(total_size);
        return true;
    }

    /// Set render target
    pub fn setRenderTarget(
        self: *Self,
        cid: u32,
        target_type: u32,
        sid: u32,
        face: u32,
        mipmap: u32,
    ) bool {
        const total_size = types.totalCmdSize(types.CmdSetRenderTarget);

        const slice = self.fifo_mgr.reserve(total_size) catch return false;

        const header: *types.CmdHeader = @ptrCast(@alignCast(&slice[0]));
        header.id = @intFromEnum(hw.Cmd3d.SetRenderTarget);
        header.size = @sizeOf(types.CmdSetRenderTarget);

        const body: *types.CmdSetRenderTarget = @ptrCast(@alignCast(&slice[@sizeOf(types.CmdHeader) / 4]));
        body.cid = cid;
        body.target_type = target_type;
        body.target = .{
            .sid = sid,
            .face = face,
            .mipmap = mipmap,
        };

        self.fifo_mgr.commit(total_size);
        return true;
    }

    // ========== Transforms ==========

    /// Set a transform matrix
    pub fn setTransform(self: *Self, cid: u32, transform_type: types.TransformType, matrix: [16]f32) bool {
        const total_size = types.totalCmdSize(types.CmdSetTransform);

        const slice = self.fifo_mgr.reserve(total_size) catch return false;

        const header: *types.CmdHeader = @ptrCast(@alignCast(&slice[0]));
        header.id = @intFromEnum(hw.Cmd3d.SetTransform);
        header.size = @sizeOf(types.CmdSetTransform);

        const body: *types.CmdSetTransform = @ptrCast(@alignCast(&slice[@sizeOf(types.CmdHeader) / 4]));
        body.cid = cid;
        body.transform_type = @intFromEnum(transform_type);
        body.matrix = matrix;

        self.fifo_mgr.commit(total_size);
        return true;
    }

    /// Set identity transform
    pub fn setIdentityTransform(self: *Self, cid: u32, transform_type: types.TransformType) bool {
        const identity = [16]f32{
            1.0, 0.0, 0.0, 0.0,
            0.0, 1.0, 0.0, 0.0,
            0.0, 0.0, 1.0, 0.0,
            0.0, 0.0, 0.0, 1.0,
        };
        return self.setTransform(cid, transform_type, identity);
    }

    // ========== Clear ==========

    /// Clear render target
    pub fn clear(
        self: *Self,
        cid: u32,
        clear_color: bool,
        clear_depth: bool,
        clear_stencil: bool,
        color: u32,
        depth: f32,
        stencil: u32,
        rect: ?types.CopyRect,
    ) bool {
        const has_rect = rect != null;
        const rect_size: u32 = if (has_rect) @sizeOf(types.CopyRect) else 0;
        const body_size = @sizeOf(types.CmdClear) + rect_size;
        const total_size = @sizeOf(types.CmdHeader) + body_size;

        const slice = self.fifo_mgr.reserve(total_size) catch return false;

        const header: *types.CmdHeader = @ptrCast(@alignCast(&slice[0]));
        header.id = @intFromEnum(hw.Cmd3d.Clear);
        header.size = body_size;

        const body_offset = @sizeOf(types.CmdHeader) / 4;
        const body: *types.CmdClear = @ptrCast(@alignCast(&slice[body_offset]));
        body.cid = cid;
        body.flags = .{
            .color = clear_color,
            .depth = clear_depth,
            .stencil = clear_stencil,
        };
        body.color = color;
        body.depth = depth;
        body.stencil = stencil;

        if (rect) |r| {
            const rect_offset = body_offset + (@sizeOf(types.CmdClear) / 4);
            const rect_ptr: *types.CopyRect = @ptrCast(@alignCast(&slice[rect_offset]));
            rect_ptr.* = r;
        }

        self.fifo_mgr.commit(total_size);
        return true;
    }

    // ========== Present ==========

    /// Present surface to screen
    pub fn present(self: *Self, sid: u32, rects: []const types.CopyRect) bool {
        const rects_size = std.math.mul(u32, @intCast(rects.len), @sizeOf(types.CopyRect)) catch return false;
        const body_size = std.math.add(u32, @sizeOf(types.CmdPresent), rects_size) catch return false;
        const total_size = std.math.add(u32, @sizeOf(types.CmdHeader), body_size) catch return false;

        const slice = self.fifo_mgr.reserve(total_size) catch return false;

        const header: *types.CmdHeader = @ptrCast(@alignCast(&slice[0]));
        header.id = @intFromEnum(hw.Cmd3d.Present);
        header.size = body_size;

        const body_offset = @sizeOf(types.CmdHeader) / 4;
        const body: *types.CmdPresent = @ptrCast(@alignCast(&slice[body_offset]));
        body.sid = sid;

        // Copy rect data
        const rects_offset = body_offset + (@sizeOf(types.CmdPresent) / 4);
        for (rects, 0..) |r, i| {
            const rect_words = @sizeOf(types.CopyRect) / 4;
            const offset = rects_offset + (i * rect_words);
            const rect_ptr: *types.CopyRect = @ptrCast(@alignCast(&slice[offset]));
            rect_ptr.* = r;
        }

        self.fifo_mgr.commit(total_size);
        return true;
    }

    /// Present full surface to screen
    pub fn presentFullScreen(self: *Self, sid: u32, width: u32, height: u32) bool {
        const rect = types.CopyRect{
            .x = 0,
            .y = 0,
            .w = width,
            .h = height,
            .src_x = 0,
            .src_y = 0,
        };
        return self.present(sid, &[_]types.CopyRect{rect});
    }

    // ========== Viewport ==========

    /// Set viewport
    pub fn setViewport(self: *Self, cid: u32, viewport: types.Viewport) bool {
        const total_size = @sizeOf(types.CmdHeader) + @sizeOf(u32) + @sizeOf(types.Viewport);

        const slice = self.fifo_mgr.reserve(total_size) catch return false;

        const header: *types.CmdHeader = @ptrCast(@alignCast(&slice[0]));
        header.id = @intFromEnum(hw.Cmd3d.SetViewport);
        header.size = @sizeOf(u32) + @sizeOf(types.Viewport);

        // Context ID
        slice[@sizeOf(types.CmdHeader) / 4] = cid;

        // Viewport data
        const vp_offset = (@sizeOf(types.CmdHeader) + @sizeOf(u32)) / 4;
        const vp: *types.Viewport = @ptrCast(@alignCast(&slice[vp_offset]));
        vp.* = viewport;

        self.fifo_mgr.commit(total_size);
        return true;
    }

    // ========== Z Range ==========

    /// Set Z range
    pub fn setZRange(self: *Self, cid: u32, min: f32, max: f32) bool {
        const total_size = @sizeOf(types.CmdHeader) + @sizeOf(u32) + @sizeOf(types.ZRange);

        const slice = self.fifo_mgr.reserve(total_size) catch return false;

        const header: *types.CmdHeader = @ptrCast(@alignCast(&slice[0]));
        header.id = @intFromEnum(hw.Cmd3d.SetZRange);
        header.size = @sizeOf(u32) + @sizeOf(types.ZRange);

        // Context ID
        slice[@sizeOf(types.CmdHeader) / 4] = cid;

        // Z range
        const zr_offset = (@sizeOf(types.CmdHeader) + @sizeOf(u32)) / 4;
        const zr: *types.ZRange = @ptrCast(@alignCast(&slice[zr_offset]));
        zr.min = min;
        zr.max = max;

        self.fifo_mgr.commit(total_size);
        return true;
    }

    // ========== Scissor ==========

    /// Set scissor rectangle
    pub fn setScissorRect(self: *Self, cid: u32, rect: types.CopyRect) bool {
        const total_size = types.totalCmdSize(types.CmdSetScissorRect);

        const slice = self.fifo_mgr.reserve(total_size) catch return false;

        const header: *types.CmdHeader = @ptrCast(@alignCast(&slice[0]));
        header.id = @intFromEnum(hw.Cmd3d.SetScissorRect);
        header.size = @sizeOf(types.CmdSetScissorRect);

        const body: *types.CmdSetScissorRect = @ptrCast(@alignCast(&slice[@sizeOf(types.CmdHeader) / 4]));
        body.cid = cid;
        body.rect = rect;

        self.fifo_mgr.commit(total_size);
        return true;
    }
};

/// Re-export types for convenience
pub const CmdHeader = types.CmdHeader;
pub const CopyRect = types.CopyRect;
pub const Size3D = types.Size3D;
pub const Viewport = types.Viewport;
pub const ZRange = types.ZRange;
pub const RenderState = types.RenderState;
pub const TransformType = types.TransformType;
pub const PrimitiveType = types.PrimitiveType;
pub const ShaderType = types.ShaderType;
