//! Minimal OpenGL 3.3 core loader. Only the functions the renderer uses are
//! listed; `load` resolves them through the platform's GetProcAddress.
const std = @import("std");

pub const Enum = c_uint;
pub const Uint = c_uint;
pub const Int = c_int;
pub const Sizei = c_int;
pub const Float = f32;
pub const Boolean = u8;
pub const Bitfield = c_uint;
pub const Sizeiptr = isize;
pub const Intptr = isize;

pub const DEPTH_BUFFER_BIT: Bitfield = 0x00000100;
pub const COLOR_BUFFER_BIT: Bitfield = 0x00004000;
pub const TRIANGLES: Enum = 0x0004;
pub const TRIANGLE_STRIP: Enum = 0x0005;
pub const LINES: Enum = 0x0001;
pub const DEPTH_TEST: Enum = 0x0B71;
pub const CULL_FACE: Enum = 0x0B44;
pub const BLEND: Enum = 0x0BE2;
pub const MULTISAMPLE: Enum = 0x809D;
pub const SAMPLE_ALPHA_TO_COVERAGE: Enum = 0x809E;
pub const FRONT: Enum = 0x0404;
pub const BACK: Enum = 0x0405;
pub const LEQUAL: Enum = 0x0203;
pub const LESS: Enum = 0x0201;
pub const ONE: Enum = 1;
pub const SRC_ALPHA: Enum = 0x0302;
pub const ONE_MINUS_SRC_ALPHA: Enum = 0x0303;
pub const FLOAT: Enum = 0x1406;
pub const UNSIGNED_BYTE: Enum = 0x1401;
pub const UNSIGNED_SHORT: Enum = 0x1403;
pub const UNSIGNED_INT: Enum = 0x1405;
pub const RGBA: Enum = 0x1908;
pub const ARRAY_BUFFER: Enum = 0x8892;
pub const ELEMENT_ARRAY_BUFFER: Enum = 0x8893;
pub const STATIC_DRAW: Enum = 0x88E4;
pub const DYNAMIC_DRAW: Enum = 0x88E8;
pub const FRAGMENT_SHADER: Enum = 0x8B30;
pub const VERTEX_SHADER: Enum = 0x8B31;
pub const COMPILE_STATUS: Enum = 0x8B81;
pub const LINK_STATUS: Enum = 0x8B82;
pub const INFO_LOG_LENGTH: Enum = 0x8B84;
pub const PACK_ALIGNMENT: Enum = 0x0D05;
pub const FALSE: Boolean = 0;
pub const TRUE: Boolean = 1;

const Fns = struct {
    Viewport: *const fn (Int, Int, Sizei, Sizei) callconv(.c) void,
    ClearColor: *const fn (Float, Float, Float, Float) callconv(.c) void,
    Clear: *const fn (Bitfield) callconv(.c) void,
    Enable: *const fn (Enum) callconv(.c) void,
    Disable: *const fn (Enum) callconv(.c) void,
    DepthFunc: *const fn (Enum) callconv(.c) void,
    DepthMask: *const fn (Boolean) callconv(.c) void,
    BlendFunc: *const fn (Enum, Enum) callconv(.c) void,
    LineWidth: *const fn (Float) callconv(.c) void,
    CullFace: *const fn (Enum) callconv(.c) void,
    CreateShader: *const fn (Enum) callconv(.c) Uint,
    ShaderSource: *const fn (Uint, Sizei, [*]const [*:0]const u8, ?[*]const Int) callconv(.c) void,
    CompileShader: *const fn (Uint) callconv(.c) void,
    GetShaderiv: *const fn (Uint, Enum, *Int) callconv(.c) void,
    GetShaderInfoLog: *const fn (Uint, Sizei, ?*Sizei, [*]u8) callconv(.c) void,
    DeleteShader: *const fn (Uint) callconv(.c) void,
    CreateProgram: *const fn () callconv(.c) Uint,
    AttachShader: *const fn (Uint, Uint) callconv(.c) void,
    LinkProgram: *const fn (Uint) callconv(.c) void,
    GetProgramiv: *const fn (Uint, Enum, *Int) callconv(.c) void,
    GetProgramInfoLog: *const fn (Uint, Sizei, ?*Sizei, [*]u8) callconv(.c) void,
    DeleteProgram: *const fn (Uint) callconv(.c) void,
    UseProgram: *const fn (Uint) callconv(.c) void,
    GetUniformLocation: *const fn (Uint, [*:0]const u8) callconv(.c) Int,
    Uniform1f: *const fn (Int, Float) callconv(.c) void,
    Uniform1i: *const fn (Int, Int) callconv(.c) void,
    Uniform2f: *const fn (Int, Float, Float) callconv(.c) void,
    Uniform3f: *const fn (Int, Float, Float, Float) callconv(.c) void,
    UniformMatrix4fv: *const fn (Int, Sizei, Boolean, [*]const Float) callconv(.c) void,
    GenVertexArrays: *const fn (Sizei, [*]Uint) callconv(.c) void,
    DeleteVertexArrays: *const fn (Sizei, [*]const Uint) callconv(.c) void,
    BindVertexArray: *const fn (Uint) callconv(.c) void,
    GenBuffers: *const fn (Sizei, [*]Uint) callconv(.c) void,
    DeleteBuffers: *const fn (Sizei, [*]const Uint) callconv(.c) void,
    BindBuffer: *const fn (Enum, Uint) callconv(.c) void,
    BufferData: *const fn (Enum, Sizeiptr, ?*const anyopaque, Enum) callconv(.c) void,
    VertexAttribPointer: *const fn (Uint, Int, Enum, Boolean, Sizei, ?*const anyopaque) callconv(.c) void,
    EnableVertexAttribArray: *const fn (Uint) callconv(.c) void,
    VertexAttribDivisor: *const fn (Uint, Uint) callconv(.c) void,
    DrawArrays: *const fn (Enum, Int, Sizei) callconv(.c) void,
    DrawArraysInstanced: *const fn (Enum, Int, Sizei, Sizei) callconv(.c) void,
    DrawElementsInstanced: *const fn (Enum, Sizei, Enum, ?*const anyopaque, Sizei) callconv(.c) void,
    ReadPixels: *const fn (Int, Int, Sizei, Sizei, Enum, Enum, *anyopaque) callconv(.c) void,
    PixelStorei: *const fn (Enum, Int) callconv(.c) void,
    Finish: *const fn () callconv(.c) void,
};

pub var f: Fns = undefined;

pub const LoadError = error{MissingGlFunction};

/// `getProc` maps a GL function name (e.g. "glClear") to its address.
pub fn load(getProc: *const fn ([*:0]const u8) ?*const anyopaque) LoadError!void {
    inline for (@typeInfo(Fns).@"struct".field_names) |name| {
        const ptr = getProc("gl" ++ name) orelse {
            std.log.err("missing GL function gl{s}", .{name});
            return error.MissingGlFunction;
        };
        @field(f, name) = @ptrCast(@alignCast(ptr));
    }
}

pub fn compileProgram(vs_src: [:0]const u8, fs_src: [:0]const u8) !Uint {
    const vs = try compileShader(VERTEX_SHADER, vs_src);
    defer f.DeleteShader(vs);
    const fs = try compileShader(FRAGMENT_SHADER, fs_src);
    defer f.DeleteShader(fs);
    const p = f.CreateProgram();
    f.AttachShader(p, vs);
    f.AttachShader(p, fs);
    f.LinkProgram(p);
    var ok: Int = 0;
    f.GetProgramiv(p, LINK_STATUS, &ok);
    if (ok == 0) {
        var log_buf: [4096]u8 = undefined;
        var len: Sizei = 0;
        f.GetProgramInfoLog(p, log_buf.len, &len, &log_buf);
        std.log.err("GL link failed: {s}", .{log_buf[0..@intCast(len)]});
        return error.ShaderLink;
    }
    return p;
}

fn compileShader(kind: Enum, src: [:0]const u8) !Uint {
    const s = f.CreateShader(kind);
    const srcs = [_][*:0]const u8{src.ptr};
    f.ShaderSource(s, 1, &srcs, null);
    f.CompileShader(s);
    var ok: Int = 0;
    f.GetShaderiv(s, COMPILE_STATUS, &ok);
    if (ok == 0) {
        var log_buf: [4096]u8 = undefined;
        var len: Sizei = 0;
        f.GetShaderInfoLog(s, log_buf.len, &len, &log_buf);
        std.log.err("GL shader compile failed: {s}", .{log_buf[0..@intCast(len)]});
        return error.ShaderCompile;
    }
    return s;
}
