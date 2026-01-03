//! SVGA3D Type Definitions
//!
//! Structure definitions for VMware SVGA3D commands and resources.
//! Based on VMware SVGA3D specification.

const std = @import("std");
const hw = @import("hardware.zig");

/// SVGA3D command header (prefixes all 3D commands)
pub const CmdHeader = extern struct {
    /// Command ID (from Cmd3d enum)
    id: u32,
    /// Size of command body in bytes (excludes header)
    size: u32,
};

/// Surface face description (for cubemaps and arrays)
pub const SurfaceFace = extern struct {
    /// Number of mipmap levels for this face
    num_mip_levels: u32,
};

/// Surface size descriptor
pub const Size3D = extern struct {
    width: u32,
    height: u32,
    depth: u32,
};

/// Rectangle copy descriptor
pub const CopyRect = extern struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    src_x: u32,
    src_y: u32,
};

/// Box descriptor for 3D copies
pub const Box = extern struct {
    x: u32,
    y: u32,
    z: u32,
    w: u32,
    h: u32,
    d: u32,
};

/// Viewport definition
pub const Viewport = extern struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    min_depth: f32,
    max_depth: f32,
};

/// Z-range definition
pub const ZRange = extern struct {
    min: f32,
    max: f32,
};

/// Render state value (variant type)
pub const RenderStateValue = extern union {
    uint_value: u32,
    float_value: f32,
};

/// Material definition
pub const Material = extern struct {
    diffuse: [4]f32, // RGBA
    ambient: [4]f32,
    specular: [4]f32,
    emissive: [4]f32,
    shininess: f32,
};

/// Light data
pub const LightData = extern struct {
    light_type: u32,
    in_world_space: u32,
    diffuse: [4]f32,
    specular: [4]f32,
    ambient: [4]f32,
    position: [4]f32,
    direction: [4]f32,
    range: f32,
    falloff: f32,
    attenuation0: f32,
    attenuation1: f32,
    attenuation2: f32,
    theta: f32,
    phi: f32,
};

/// Clip plane definition
pub const ClipPlane = extern struct {
    plane: [4]f32,
};

/// Clear flags
pub const ClearFlags = packed struct(u32) {
    color: bool,
    depth: bool,
    stencil: bool,
    _reserved: u29 = 0,
};

/// Clear command body
pub const CmdClear = extern struct {
    cid: u32,
    flags: ClearFlags,
    color: u32,
    depth: f32,
    stencil: u32,
    // Followed by array of CopyRect for clear regions
};

/// Surface define command body
pub const CmdSurfaceDefine = extern struct {
    sid: u32,
    surface_flags: u32,
    format: hw.SurfaceFormat,
    /// For cubemaps: 6 faces. For regular textures: 1 face
    face: [6]SurfaceFace,
    // Followed by array of Size3D for mip levels
};

/// Surface define v2 (extended)
pub const CmdSurfaceDefineV2 = extern struct {
    sid: u32,
    surface_flags: u32,
    format: hw.SurfaceFormat,
    num_mip_levels: u32,
    multisample_count: u32,
    autogen_filter: u32,
    size: Size3D,
    array_size: u32,
};

/// Surface destroy command
pub const CmdSurfaceDestroy = extern struct {
    sid: u32,
};

/// Context define command
pub const CmdContextDefine = extern struct {
    cid: u32,
};

/// Context destroy command
pub const CmdContextDestroy = extern struct {
    cid: u32,
};

/// Set render target command
pub const CmdSetRenderTarget = extern struct {
    cid: u32,
    target_type: u32,
    target: RenderTargetView,
};

/// Render target view
pub const RenderTargetView = extern struct {
    sid: u32,
    face: u32,
    mipmap: u32,
};

/// Set transform command
pub const CmdSetTransform = extern struct {
    cid: u32,
    transform_type: u32,
    matrix: [16]f32,
};

/// Set render state command
pub const CmdSetRenderState = extern struct {
    cid: u32,
    state: u32,
    value: u32,
};

/// Set texture state command
pub const CmdSetTextureState = extern struct {
    cid: u32,
    // Followed by array of TextureState
};

/// Texture state entry
pub const TextureState = extern struct {
    stage: u32,
    name: u32,
    value: u32,
};

/// Present command
pub const CmdPresent = extern struct {
    sid: u32,
    // Followed by array of CopyRect for regions to present
};

/// Draw primitives command
pub const CmdDrawPrimitives = extern struct {
    cid: u32,
    num_vertex_decls: u32,
    num_ranges: u32,
    // Followed by vertex declarations and ranges
};

/// Vertex declaration entry
pub const VertexDecl = extern struct {
    identity: VertexDeclIdentity,
    array: VertexDeclArray,
    range_hint: VertexDeclRangeHint,
};

/// Vertex declaration identity
pub const VertexDeclIdentity = extern struct {
    component_type: u32,
    usage: u32,
    usage_index: u32,
};

/// Vertex declaration array info
pub const VertexDeclArray = extern struct {
    surface_id: u32,
    offset: u32,
    stride: u32,
};

/// Vertex declaration range hint
pub const VertexDeclRangeHint = extern struct {
    first: u32,
    last: u32,
};

/// Primitive range
pub const PrimitiveRange = extern struct {
    primitive_type: u32,
    primitive_count: u32,
    index_array: IndexArray,
};

/// Index array descriptor
pub const IndexArray = extern struct {
    surface_id: u32,
    offset: u32,
    stride: u32,
};

/// Shader define command
pub const CmdShaderDefine = extern struct {
    cid: u32,
    shid: u32,
    shader_type: u32,
    // Followed by shader bytecode
};

/// Shader destroy command
pub const CmdShaderDestroy = extern struct {
    cid: u32,
    shid: u32,
    shader_type: u32,
};

/// Set shader command
pub const CmdSetShader = extern struct {
    cid: u32,
    shader_type: u32,
    shid: u32,
};

/// Set shader constant command
pub const CmdSetShaderConst = extern struct {
    cid: u32,
    reg: u32,
    shader_type: u32,
    const_type: u32,
    // Followed by constant values
};

/// DMA transfer command
pub const CmdSurfaceDMA = extern struct {
    guest: GuestImage,
    host: HostImage,
    transfer: TransferType,
    // Followed by array of Box for copy regions
};

/// Guest image descriptor
pub const GuestImage = extern struct {
    ptr: GuestPtr,
    pitch: u32,
};

/// Guest memory pointer
pub const GuestPtr = extern struct {
    gmr_id: u32,
    offset: u32,
};

/// Host image descriptor
pub const HostImage = extern struct {
    sid: u32,
    face: u32,
    mipmap: u32,
};

/// Transfer type
pub const TransferType = enum(u32) {
    /// Transfer from guest to host
    write = 0,
    /// Transfer from host to guest
    read = 1,
};

/// Scissor rect command
pub const CmdSetScissorRect = extern struct {
    cid: u32,
    rect: CopyRect,
};

/// Begin query command
pub const CmdBeginQuery = extern struct {
    cid: u32,
    query_type: u32,
};

/// End query command
pub const CmdEndQuery = extern struct {
    cid: u32,
    query_type: u32,
    gmr_id: u32,
    offset: u32,
};

/// Wait for query command
pub const CmdWaitForQuery = extern struct {
    cid: u32,
    query_type: u32,
    gmr_id: u32,
    offset: u32,
};

// SVGA3D Render State Types
pub const RenderState = enum(u32) {
    ZENABLE = 1,
    ZWRITEENABLE = 2,
    ALPHATESTENABLE = 3,
    DITHERENABLE = 4,
    BLENDENABLE = 5,
    FOGENABLE = 6,
    SPECULARENABLE = 7,
    STENCILENABLE = 8,
    LIGHTINGENABLE = 9,
    NORMALIZENORMALS = 10,
    POINTSPRITEENABLE = 11,
    POINTSCALEENABLE = 12,
    STENCILREF = 13,
    STENCILMASK = 14,
    STENCILWRITEMASK = 15,
    FOGSTART = 16,
    FOGEND = 17,
    FOGDENSITY = 18,
    POINTSIZE = 19,
    POINTSIZEMIN = 20,
    POINTSIZEMAX = 21,
    POINTSCALE_A = 22,
    POINTSCALE_B = 23,
    POINTSCALE_C = 24,
    FOGCOLOR = 25,
    AMBIENT = 26,
    CLIPPLANEENABLE = 27,
    FOGMODE = 28,
    FILLMODE = 29,
    SHADEMODE = 30,
    LINEPATTERN = 31,
    SRCBLEND = 32,
    DSTBLEND = 33,
    BLENDEQUATION = 34,
    CULLMODE = 35,
    ZFUNC = 36,
    ALPHAFUNC = 37,
    ALPHAREF = 38,
    FRONTWINDING = 39,
    COORDINATETYPE = 40,
    ZBIAS = 41,
    RANGEFOGENABLE = 42,
    COLORWRITEENABLE = 43,
    VERTEXMATERIALENABLE = 44,
    DIFFUSEMATERIALSOURCE = 45,
    SPECULARMATERIALSOURCE = 46,
    AMBIENTMATERIALSOURCE = 47,
    EMISSIVEMATERIALSOURCE = 48,
    TEXTUREFACTOR = 49,
    LOCALVIEWER = 50,
    SCISSORTESTENABLE = 51,
    BLENDCOLOR = 52,
    STENCILOPS = 53,
    STENCIL_CCW_OPS = 54,
    STENCILFUNC = 55,
    STENCIL_CCW_FUNC = 56,
    STENCILTWOSIDED = 57,
    MULTISAMPLEANTIALIAS = 58,
    MULTISAMPLEMASK = 59,
    INDEXEDVERTEXBLENDENABLE = 60,
    TWEENFACTOR = 61,
    ANTIALIASEDLINEENABLE = 62,
    COLORWRITEENABLE1 = 63,
    COLORWRITEENABLE2 = 64,
    COLORWRITEENABLE3 = 65,
    SEPARATEALPHABLENDENABLE = 66,
    SRCBLENDALPHA = 67,
    DSTBLENDALPHA = 68,
    BLENDEQUATIONALPHA = 69,
    TRANSPARENCYANTIALIAS = 70,
    LINEWIDTH = 71,
    MAX = 72,
};

// Transform Types
pub const TransformType = enum(u32) {
    WORLD = 0,
    VIEW = 1,
    PROJECTION = 2,
    TEXTURE0 = 3,
    TEXTURE1 = 4,
    TEXTURE2 = 5,
    TEXTURE3 = 6,
    TEXTURE4 = 7,
    TEXTURE5 = 8,
    TEXTURE6 = 9,
    TEXTURE7 = 10,
    WORLD1 = 11,
    WORLD2 = 12,
    WORLD3 = 13,
    MAX = 14,
};

// Primitive Types
pub const PrimitiveType = enum(u32) {
    INVALID = 0,
    TRIANGLELIST = 1,
    POINTLIST = 2,
    LINELIST = 3,
    LINESTRIP = 4,
    TRIANGLESTRIP = 5,
    TRIANGLEFAN = 6,
    MAX = 7,
};

// Shader Types
pub const ShaderType = enum(u32) {
    VERTEX = 0,
    PIXEL = 1,
    MAX = 2,
};

// Helper to calculate command size
pub fn cmdSize(comptime T: type) u32 {
    return @sizeOf(T);
}

// Helper to calculate total command size with header
pub fn totalCmdSize(comptime T: type) u32 {
    return @sizeOf(CmdHeader) + @sizeOf(T);
}
