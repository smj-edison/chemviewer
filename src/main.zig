const std = @import("std");
const c = @import("c");
pub fn main(init: std.process.Init) !void {
    _ = init;
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SdlInit;
    defer c.SDL_Quit();
    _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MINOR_VERSION, 3);
    _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_PROFILE_MASK, c.SDL_GL_CONTEXT_PROFILE_CORE);
    const win = c.SDL_CreateWindow("smoke", 800, 600, c.SDL_WINDOW_OPENGL | c.SDL_WINDOW_HIDDEN) orelse return error.Win;
    const ctx = c.SDL_GL_CreateContext(win) orelse return error.Ctx;
    _ = c.igCreateContext(null);
    _ = c.ImGui_ImplSDL3_InitForOpenGL(win, ctx);
    _ = c.ImGui_ImplOpenGL3_Init("#version 330");
    c.ImGui_ImplOpenGL3_NewFrame();
    c.ImGui_ImplSDL3_NewFrame();
    c.igNewFrame();
    _ = c.igBegin("hi", null, 0);
    c.igEnd();
    c.igRender();
    c.ImGui_ImplOpenGL3_RenderDrawData(c.igGetDrawData());
    std.debug.print("ok {s}\n", .{c.igGetVersion()});
}
