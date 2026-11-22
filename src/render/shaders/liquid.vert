#version 450
// Liquid glass blobs: one camera-facing quad per atom, covering its
// bounding sphere (the atom, its bonds up to where its neighbours take
// over, and the smooth blend between them). liquid.frag ray-marches the
// surface inside it.
#include "common.glsl"

layout(location = 0) in vec2 a_corner;
layout(location = 1) in vec4 a_center_radius;
layout(location = 2) in vec4 a_color;
layout(location = 3) in vec2 a_bound_highlight;
layout(location = 4) in uvec2 a_links;

layout(location = 0) out vec3 v_view_pos;
layout(location = 1) flat out vec4 v_center_radius;
layout(location = 2) flat out vec4 v_color;
layout(location = 3) flat out vec2 v_bound_highlight;
layout(location = 4) flat out uvec2 v_links;

void main() {
    vec3 c = (u_view * vec4(a_center_radius.xyz, 1.0)).xyz;
    float rb = a_bound_highlight.x;
    float d = length(c);
    // Enlarge the quad so the perspective silhouette is always covered
    // (and cover the whole view if the camera is inside the bound).
    float s = rb * 1.3 * d / sqrt(max(d * d - rb * rb, 1e-4 * d * d));
    v_view_pos = c + vec3(a_corner * s, 0.0);
    v_center_radius = a_center_radius;
    v_color = a_color;
    v_bound_highlight = a_bound_highlight;
    v_links = a_links;
    gl_Position = toVulkanDepth(u_proj * vec4(v_view_pos, 1.0));
}
