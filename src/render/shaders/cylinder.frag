#version 450
#include "common.glsl"
#include "lighting.glsl"
#include "glass.glsl"

layout(location = 0) in vec3 v_normal;
layout(location = 1) in vec3 v_view_pos;
layout(location = 2) in float v_t;
layout(location = 3) flat in vec4 v_ca;
layout(location = 4) flat in vec4 v_cb;
layout(location = 5) flat in float v_outline_a;

layout(location = 0) out vec4 o_color;

void main() {
    if (u_outline_pass == 1) {
        if (v_outline_a <= 0.003) discard;
        o_color = vec4(u_outline_color, v_outline_a);
        gl_FragDepth = gl_FragCoord.z;
        return;
    }
    if (u_shadow_pass > 0.5) {
        o_color = vec4(u_shadow_color, 1.0);
        gl_FragDepth = 0.999999;
        return;
    }
    gl_FragDepth = gl_FragCoord.z;
    vec4 c = v_t < 0.5 ? v_ca : v_cb;
    vec3 n = normalize(v_normal);
    vec3 col = shade(c.rgb, n, normalize(-v_view_pos));
    if (u_cel == 3) {
        // Thickness: twice the bond radius times the cosine (approximately).
        col = glass(c.rgb, n, v_view_pos, 0.25 * max(dot(n, normalize(-v_view_pos)), 0.0), 0.45);
    }
    o_color = vec4(fogged(col, -v_view_pos.z), c.a);
}
