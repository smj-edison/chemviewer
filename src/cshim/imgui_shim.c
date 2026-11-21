#define CIMGUI_DEFINE_ENUMS_AND_STRUCTS
#include "cimgui.h"
#include "imgui_shim.h"

void cvImGuiCreateContext(void) {
    igCreateContext(NULL);
    ImGuiIO *io = igGetIO_Nil();
    io->IniFilename = NULL; // settings persistence will go through std.Io
    // No keyboard navigation: it captures the keyboard whenever a panel has
    // focus, which would swallow the viewer's shortcuts (Space, arrows, Ctrl+C).
}

void cvImGuiDestroyContext(void) { igDestroyContext(NULL); }
bool cvImGuiWantCaptureMouse(void) { return igGetIO_Nil()->WantCaptureMouse; }
bool cvImGuiWantTextInput(void) { return igGetIO_Nil()->WantTextInput; }
