// Every C API the viewer uses, translated once by `b.addTranslateC`.
// Zig code accesses it as `@import("c")`.
#define SDL_MAIN_HANDLED
#include <SDL3/SDL.h>
#include <SDL3/SDL_vulkan.h>

#define CIMGUI_DEFINE_ENUMS_AND_STRUCTS
#define CIMGUI_USE_SDL3
#include "cimgui.h"
#include "cimgui_impl.h"
#include "imgui_shim.h"
#include "imgui_vulkan.h"
