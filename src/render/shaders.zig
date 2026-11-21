//! GLSL 330 core shaders.
//!
//! Shading modes (u_cel): 1 = cel/toon (flat bands, no highlights),
//! 0 = smooth Blinn-Phong. Outlines have a constant screen width:
//! `u_outline_k` is the outline width in world units per unit of view depth.

const lighting =
    \\uniform int u_cel;
    \\vec3 shade(vec3 base, vec3 n, vec3 v) {
    \\    vec3 l = normalize(vec3(0.35, 0.45, 1.0));
    \\    float diff = max(dot(n, l), 0.0);
    \\    if (u_cel == 1) {
    \\        // Three flat bands with anti-aliased steps.
    \\        float w = max(fwidth(diff), 1e-4);
    \\        float band = 0.66
    \\            + 0.17 * smoothstep(0.20 - w, 0.20 + w, diff)
    \\            + 0.17 * smoothstep(0.62 - w, 0.62 + w, diff);
    \\        return base * band;
    \\    }
    \\    float spec = pow(max(dot(n, normalize(l + v)), 0.0), 48.0) * 0.35;
    \\    float rim = pow(1.0 - max(dot(n, v), 0.0), 3.0) * 0.15;
    \\    return base * (0.22 + 0.78 * diff) + vec3(spec + rim);
    \\}
    \\
;

/// Atoms: camera-facing quads, ray-cast to exact spheres in the fragment
/// shader. A slightly larger concentric sphere provides the outline ring.
pub const sphere_vs =
    \\#version 330 core
    \\layout(location = 0) in vec2 a_corner;
    \\layout(location = 1) in vec4 a_center_radius;
    \\layout(location = 2) in vec4 a_color;
    \\uniform mat4 u_view;
    \\uniform mat4 u_proj;
    \\uniform float u_outline_k;
    \\out vec3 v_view_pos;
    \\flat out vec3 v_center;
    \\flat out float v_radius;
    \\flat out float v_outer;
    \\flat out vec4 v_color;
    \\void main() {
    \\    vec3 c = (u_view * vec4(a_center_radius.xyz, 1.0)).xyz;
    \\    float r = a_center_radius.w;
    \\    float d = length(c);
    \\    float ro = r + u_outline_k * d;
    \\    // Enlarge the quad so the perspective silhouette is always covered.
    \\    float s = ro * 1.3 * d / sqrt(max(d * d - ro * ro, 1e-4));
    \\    v_view_pos = c + vec3(a_corner * s, 0.0);
    \\    v_center = c;
    \\    v_radius = r;
    \\    v_outer = ro;
    \\    v_color = a_color;
    \\    gl_Position = u_proj * vec4(v_view_pos, 1.0);
    \\}
;

pub const sphere_fs =
    \\#version 330 core
    \\in vec3 v_view_pos;
    \\flat in vec3 v_center;
    \\flat in float v_radius;
    \\flat in float v_outer;
    \\flat in vec4 v_color;
    \\uniform mat4 u_proj;
    \\uniform vec3 u_outline_color;
    \\out vec4 o_color;
    \\
++ lighting ++
    \\void main() {
    \\    vec3 d = normalize(v_view_pos);
    \\    float b = dot(d, v_center);
    \\    float cc = dot(v_center, v_center);
    \\    float disc_o = b * b - (cc - v_outer * v_outer);
    \\    if (disc_o < 0.0) discard;
    \\    float disc_i = b * b - (cc - v_radius * v_radius);
    \\    bool inner = disc_i > 0.0;
    \\    float t = b - sqrt(inner ? disc_i : disc_o);
    \\    vec3 p = d * t;
    \\    // Normal of the inner sphere (clamped to its silhouette near the edge).
    \\    vec3 n = normalize(p - v_center);
    \\    vec3 body = shade(v_color.rgb, n, -d);
    \\    float k = 1.0;
    \\    if (v_outer > v_radius) k = clamp(disc_i / max(fwidth(disc_i), 1e-9) + 0.5, 0.0, 1.0);
    \\    vec4 clip = u_proj * vec4(p, 1.0);
    \\    gl_FragDepth = clip.z / clip.w * 0.5 + 0.5;
    \\    // Outer edge coverage drives alpha-to-coverage for smooth silhouettes.
    \\    float cover = clamp(disc_o / max(fwidth(disc_o), 1e-9), 0.0, 1.0);
    \\    o_color = vec4(mix(u_outline_color, body, k), v_color.a * cover);
    \\}
;

/// Bonds: unit cylinder mesh (x=cos, y=sin, z=0..1) instanced between two
/// points. Colour switches from A to B at the midpoint. With u_outline_pass,
/// the cylinder is inflated and drawn back-faces-only in the outline colour
/// (an "inverted hull" outline).
pub const cylinder_vs =
    \\#version 330 core
    \\layout(location = 0) in vec3 a_vert;
    \\layout(location = 1) in vec4 a_start_radius;
    \\layout(location = 2) in vec4 a_end;
    \\layout(location = 3) in vec4 a_color_a;
    \\layout(location = 4) in vec4 a_color_b;
    \\uniform mat4 u_view;
    \\uniform mat4 u_proj;
    \\uniform float u_outline_k;
    \\uniform int u_outline_pass;
    \\out vec3 v_normal;
    \\out vec3 v_view_pos;
    \\out float v_t;
    \\flat out vec4 v_ca;
    \\flat out vec4 v_cb;
    \\flat out float v_outline_a;
    \\void main() {
    \\    vec3 a = a_start_radius.xyz;
    \\    vec3 axis = a_end.xyz - a;
    \\    vec3 w = axis / max(length(axis), 1e-6);
    \\    vec3 tmp = abs(w.x) < 0.9 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0);
    \\    vec3 u = normalize(cross(w, tmp));
    \\    vec3 v = cross(w, u);
    \\    vec3 n = u * a_vert.x + v * a_vert.y;
    \\    float radius = a_start_radius.w;
    \\    if (u_outline_pass == 1) {
    \\        float depth = -(u_view * vec4(a + 0.5 * axis, 1.0)).z;
    \\        // a_end.w = outline weight: scales width here, opacity in the FS.
    \\        radius += u_outline_k * max(depth, 0.0) * a_end.w;
    \\    }
    \\    vec3 world = a + axis * a_vert.z + n * radius;
    \\    vec4 vp = u_view * vec4(world, 1.0);
    \\    v_normal = mat3(u_view) * n;
    \\    v_view_pos = vp.xyz;
    \\    v_t = a_vert.z;
    \\    v_ca = a_color_a;
    \\    v_cb = a_color_b;
    \\    v_outline_a = a_end.w * min(a_color_a.a, a_color_b.a);
    \\    gl_Position = u_proj * vp;
    \\}
;

pub const cylinder_fs =
    \\#version 330 core
    \\in vec3 v_normal;
    \\in vec3 v_view_pos;
    \\in float v_t;
    \\flat in vec4 v_ca;
    \\flat in vec4 v_cb;
    \\flat in float v_outline_a;
    \\uniform int u_outline_pass;
    \\uniform vec3 u_outline_color;
    \\out vec4 o_color;
    \\
++ lighting ++
    \\void main() {
    \\    if (u_outline_pass == 1) {
    \\        if (v_outline_a <= 0.003) discard;
    \\        o_color = vec4(u_outline_color, v_outline_a);
    \\        return;
    \\    }
    \\    vec4 c = v_t < 0.5 ? v_ca : v_cb;
    \\    o_color = vec4(shade(c.rgb, normalize(v_normal), normalize(-v_view_pos)), c.a);
    \\}
;

pub const line_vs =
    \\#version 330 core
    \\layout(location = 0) in vec3 a_pos;
    \\layout(location = 1) in vec4 a_color;
    \\uniform mat4 u_view;
    \\uniform mat4 u_proj;
    \\out vec4 v_color;
    \\void main() {
    \\    v_color = a_color;
    \\    gl_Position = u_proj * u_view * vec4(a_pos, 1.0);
    \\}
;

pub const line_fs =
    \\#version 330 core
    \\in vec4 v_color;
    \\out vec4 o_color;
    \\void main() { o_color = v_color; }
;
