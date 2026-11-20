//! GLSL 330 core shaders.

const lighting =
    \\vec3 shade(vec3 base, vec3 n, vec3 v) {
    \\    vec3 l = normalize(vec3(0.35, 0.45, 1.0));
    \\    float diff = max(dot(n, l), 0.0);
    \\    float spec = pow(max(dot(n, normalize(l + v)), 0.0), 48.0) * 0.35;
    \\    float rim = pow(1.0 - max(dot(n, v), 0.0), 3.0) * 0.15;
    \\    return base * (0.22 + 0.78 * diff) + vec3(spec + rim);
    \\}
    \\
;

/// Atoms: camera-facing quads, ray-cast to exact spheres in the fragment shader.
pub const sphere_vs =
    \\#version 330 core
    \\layout(location = 0) in vec2 a_corner;
    \\layout(location = 1) in vec4 a_center_radius;
    \\layout(location = 2) in vec4 a_color;
    \\uniform mat4 u_view;
    \\uniform mat4 u_proj;
    \\out vec3 v_view_pos;
    \\flat out vec3 v_center;
    \\flat out float v_radius;
    \\flat out vec4 v_color;
    \\void main() {
    \\    vec3 c = (u_view * vec4(a_center_radius.xyz, 1.0)).xyz;
    \\    float r = a_center_radius.w;
    \\    float d = length(c);
    \\    // Enlarge the quad so the perspective silhouette is always covered.
    \\    float s = r * 1.3 * d / sqrt(max(d * d - r * r, 1e-4));
    \\    v_view_pos = c + vec3(a_corner * s, 0.0);
    \\    v_center = c;
    \\    v_radius = r;
    \\    v_color = a_color;
    \\    gl_Position = u_proj * vec4(v_view_pos, 1.0);
    \\}
;

pub const sphere_fs =
    \\#version 330 core
    \\in vec3 v_view_pos;
    \\flat in vec3 v_center;
    \\flat in float v_radius;
    \\flat in vec4 v_color;
    \\uniform mat4 u_proj;
    \\out vec4 o_color;
    \\
++ lighting ++
    \\void main() {
    \\    vec3 d = normalize(v_view_pos);
    \\    float b = dot(d, v_center);
    \\    float disc = b * b - (dot(v_center, v_center) - v_radius * v_radius);
    \\    if (disc < 0.0) discard;
    \\    float t = b - sqrt(disc);
    \\    vec3 p = d * t;
    \\    vec3 n = (p - v_center) / v_radius;
    \\    vec4 clip = u_proj * vec4(p, 1.0);
    \\    gl_FragDepth = clip.z / clip.w * 0.5 + 0.5;
    \\    o_color = vec4(shade(v_color.rgb, n, -d), v_color.a);
    \\}
;

/// Bonds: unit cylinder mesh (x=cos, y=sin, z=0..1) instanced between two points.
/// The colour switches from colour A to colour B at the midpoint.
pub const cylinder_vs =
    \\#version 330 core
    \\layout(location = 0) in vec3 a_vert;
    \\layout(location = 1) in vec4 a_start_radius;
    \\layout(location = 2) in vec4 a_end;
    \\layout(location = 3) in vec4 a_color_a;
    \\layout(location = 4) in vec4 a_color_b;
    \\uniform mat4 u_view;
    \\uniform mat4 u_proj;
    \\out vec3 v_normal;
    \\out vec3 v_view_pos;
    \\out float v_t;
    \\flat out vec4 v_ca;
    \\flat out vec4 v_cb;
    \\void main() {
    \\    vec3 a = a_start_radius.xyz;
    \\    vec3 axis = a_end.xyz - a;
    \\    vec3 w = axis / max(length(axis), 1e-6);
    \\    vec3 tmp = abs(w.x) < 0.9 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0);
    \\    vec3 u = normalize(cross(w, tmp));
    \\    vec3 v = cross(w, u);
    \\    vec3 n = u * a_vert.x + v * a_vert.y;
    \\    vec3 world = a + axis * a_vert.z + n * a_start_radius.w;
    \\    vec4 vp = u_view * vec4(world, 1.0);
    \\    v_normal = mat3(u_view) * n;
    \\    v_view_pos = vp.xyz;
    \\    v_t = a_vert.z;
    \\    v_ca = a_color_a;
    \\    v_cb = a_color_b;
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
    \\out vec4 o_color;
    \\
++ lighting ++
    \\void main() {
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
