#define CIMGUI_DEFINE_ENUMS_AND_STRUCTS
#include "cimgui.h"
#include "imgui_shim.h"

void cvImGuiCreateContext(void) {
    igCreateContext(NULL);
    ImGuiIO *io = igGetIO_Nil();
    io->IniFilename = NULL; // settings persistence will go through std.Io
    io->ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
}

void cvImGuiDestroyContext(void) { igDestroyContext(NULL); }
bool cvImGuiWantCaptureMouse(void) { return igGetIO_Nil()->WantCaptureMouse; }
bool cvImGuiWantCaptureKeyboard(void) { return igGetIO_Nil()->WantCaptureKeyboard; }
