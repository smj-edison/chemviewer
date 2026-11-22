#version 450
// Atoms: camera-facing quads, ray-cast to exact spheres in the fragment
// shader. A slightly larger concentric sphere provides the outline ring.
#include "common.glsl"

layout(location = 0) in vec2 a_corner;
layout(location = 1) in vec4 a_center_radius;
layout(location = 2) in vec4 a_color;
layout(location = 3) in float a_highlight;

layout(location = 0) out vec3 v_view_pos;
layout(location = 1) flat out float v_highlight;
layout(location = 2) flat out vec3 v_center;
layout(location = 3) flat out float v_radius;
layout(location = 4) flat out float v_outer;
layout(location = 5) flat out vec4 v_color;

void main() {
    vec3 c = (u_view * vec4(a_center_radius.xyz, 1.0)).xyz;
    float r = a_center_radius.w;
    float d = length(c);
    // Selected atoms get a wider ring (in the accent colour) even without outlines.
    float ro = r + (a_highlight > 0.0 ? max(u_select_k, u_outline_k) : u_outline_k) * d;
    if (u_shadow_soft == 1) ro = r * 1.5; // room for the feathered edge
    v_highlight = a_highlight;
    // Enlarge the quad so the perspective silhouette is always covered.
    float s = ro * 1.3 * d / sqrt(max(d * d - ro * ro, 1e-4));
    v_view_pos = c + vec3(a_corner * s, 0.0);
    v_center = c;
    v_radius = r;
    v_outer = ro;
    v_color = a_color;
    gl_Position = u_proj * vec4(v_view_pos, 1.0);
    gl_Position.xy += u_shadow_offset * gl_Position.w;
    gl_Position = toVulkanDepth(gl_Position);
}
