// Small C helpers for ImGui calls whose declarations translate-c can't
// express (ImGuiContext gets demoted to an opaque type, but is then referenced
// through [*c] pointers, which Zig rejects). Zig never touches ImGuiIO directly.
#pragma once
#include <stdbool.h>

void cvImGuiCreateContext(void);
void cvImGuiDestroyContext(void);
bool cvImGuiWantCaptureMouse(void);
// True while a text field is being edited: app shortcuts should yield.
bool cvImGuiWantTextInput(void);
