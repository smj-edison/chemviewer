#version 450
// Plain theme background, multiplied over the soft-shadow factors when the
// backdrop pattern is off (see Renderer.draw).
#include "common.glsl"

layout(location = 0) in vec2 v_ndc;
layout(location = 0) out vec4 o_color;

void main() {
    o_color = vec4(u_bg, 1.0);
}
