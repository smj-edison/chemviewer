#version 450
#include "common.glsl"
#include "lighting.glsl"

layout(location = 0) in vec3 v_view_pos;
layout(location = 1) flat in float v_highlight;
layout(location = 2) flat in vec3 v_center;
layout(location = 3) flat in float v_radius;
layout(location = 4) flat in float v_outer;
layout(location = 5) flat in vec4 v_color;

layout(location = 0) out vec4 o_color;

void main() {
    vec3 d = normalize(v_view_pos);
    float b = dot(d, v_center);
    float cc = dot(v_center, v_center);
    float disc_o = b * b - (cc - v_outer * v_outer);
    if (disc_o < 0.0) discard;
    float disc_i = b * b - (cc - v_radius * v_radius);
    bool inner = disc_i > 0.0;
    float t = b - sqrt(inner ? disc_i : disc_o);
    vec3 p = d * t;
    // Normal of the inner sphere (clamped to its silhouette near the edge).
    vec3 n = normalize(p - v_center);
    vec3 body = shade(v_color.rgb, n, -d);
    if (u_cel == 2) {
        // Lighter dots of the same hue, up and to the right: a big one
        // and a small one. Placed on the disc (n.xy), so they scale
        // with the atom and stay put as the view rotates.
        vec2 q = n.xy;
        // Clamped: at the silhouette the derivatives blow up and would
        // smear the dots into a pale rim.
        float aa = min(max(fwidth(q.x), fwidth(q.y)), 0.06);
        float dots = min(length(q - vec2(0.12, 0.14)) - 0.30, length(q - vec2(0.52, 0.12)) - 0.13);
        body = mix(body, mix(body, vec3(1.0), 0.32), 1.0 - smoothstep(-aa, aa, dots));
        body = fogged(body, -p.z);
    }
    float k = 1.0;
    if (v_outer > v_radius) k = clamp(disc_i / max(fwidth(disc_i), 1e-9) + 0.5, 0.0, 1.0);
    vec4 clip = u_proj * vec4(p, 1.0);
    gl_FragDepth = clip.z / clip.w * 0.5 + 0.5;
    // Outer edge coverage drives alpha-to-coverage for smooth silhouettes.
    float cover = clamp(disc_o / max(fwidth(disc_o), 1e-9), 0.0, 1.0);
    vec3 edge = u_outline_color;
    vec3 ring = v_highlight > 0.0 ? u_select_color : edge;
    o_color = vec4(mix(ring, body, k), v_color.a * cover);
    if (u_shadow_pass > 0.5) {
        // Multiply factor (blended with DST_COLOR), at one fixed depth.
        // Edge coverage goes to alpha-to-coverage (alpha is not blended).
        o_color = vec4(u_shadow_color, cover);
        gl_FragDepth = 0.999999;
    }
}
