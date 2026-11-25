#version 450
// Bonds: unit cylinder mesh (x=cos, y=sin, z=0..1) instanced between two
// points. Colour switches from A to B at the midpoint. With u_outline_pass,
// the cylinder is inflated and drawn back-faces-only in the outline colour
// (an "inverted hull" outline).
#include "common.glsl"

layout(location = 0) in vec3 a_vert;
layout(location = 1) in vec4 a_start_radius;
layout(location = 2) in vec4 a_end;
layout(location = 3) in vec4 a_color_a;
layout(location = 4) in vec4 a_color_b;
layout(location = 5) in vec2 a_atom_radii;

layout(location = 0) out vec3 v_normal;
layout(location = 1) out vec3 v_view_pos;
layout(location = 2) out float v_t;
layout(location = 3) flat out vec4 v_ca;
layout(location = 4) flat out vec4 v_cb;
layout(location = 5) flat out float v_outline_a;
// The bond's atoms in view space (xyz) and their radii (w).
layout(location = 6) flat out vec4 v_atom_a;
layout(location = 7) flat out vec4 v_atom_b;

void main() {
    vec3 a = a_start_radius.xyz;
    vec3 axis = a_end.xyz - a;
    vec3 w = axis / max(length(axis), 1e-6);
    vec3 tmp = abs(w.x) < 0.9 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0);
    vec3 u = normalize(cross(w, tmp));
    vec3 v = cross(w, u);
    vec3 n = u * a_vert.x + v * a_vert.y;
    float radius = a_start_radius.w;
    if (u_outline_pass == 1) {
        float depth = -(u_view * vec4(a + 0.5 * axis, 1.0)).z;
        // a_end.w = outline weight: scales width here, opacity in the FS.
        radius += u_outline_k * max(depth, 0.0) * a_end.w;
    }
    if (u_shadow_soft == 1) radius *= 1.7; // room for the feathered edge
    vec3 world = a + axis * a_vert.z + n * radius;
    vec4 vp = u_view * vec4(world, 1.0);
    v_normal = mat3(u_view) * n;
    v_view_pos = vp.xyz;
    v_t = a_vert.z;
    v_ca = a_color_a;
    v_cb = a_color_b;
    v_outline_a = a_end.w * min(a_color_a.a, a_color_b.a);
    v_atom_a = vec4((u_view * vec4(a, 1.0)).xyz, a_atom_radii.x);
    v_atom_b = vec4((u_view * vec4(a_end.xyz, 1.0)).xyz, a_atom_radii.y);
    gl_Position = u_proj * vp;
    gl_Position.xy += u_shadow_offset * gl_Position.w;
    gl_Position = toVulkanDepth(gl_Position);
}
