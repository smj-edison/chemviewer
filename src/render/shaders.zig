//! GLSL 330 core shaders.
//!
//! Shading modes (u_cel): 1 = cel/toon (flat bands, no highlights),
//! 0 = smooth Blinn-Phong, 2 = Kurzgesagt-style flat crescents (a flat
//! fill with a hard-edged cool shadow, a warm lit crescent and a glint). Outlines have a constant screen width:
//! `u_outline_k` is the outline width in world units per unit of view depth.

const lighting =
    \\uniform int u_cel;
    \\vec3 shade(vec3 base, vec3 n, vec3 v) {
    \\    if (u_cel == 2) {
    \\        // Light from the upper left and a little in front, so a
    \\        // clear shadow crescent shows on the lower right.
    \\        vec3 kl = normalize(vec3(-0.55, 0.6, 0.55));
    \\        float d = dot(n, kl);
    \\        float w = max(fwidth(d), 1e-4);
    \\        // Shadows shift toward violet, lit areas toward warm white.
    \\        vec3 shadow = mix(base * 0.62, vec3(0.16, 0.10, 0.42), 0.30);
    \\        vec3 lit = mix(base, vec3(1.0, 0.98, 0.92), 0.30);
    \\        vec3 col = mix(shadow, base, smoothstep(0.22 - w, 0.22 + w, d));
    \\        col = mix(col, lit, smoothstep(0.70 - w, 0.70 + w, d));
    \\        // Rim light on the shadow edge: a thin band of reflected sky.
    \\        float rim = 1.0 - max(dot(n, v), 0.0);
    \\        float rw = max(fwidth(rim), 1e-4);
    \\        float rim_band = smoothstep(0.78 - rw, 0.78 + rw, rim) * (1.0 - smoothstep(-0.2, 0.15, d));
    \\        col = mix(col, mix(base, vec3(0.55, 0.75, 1.0), 0.45), rim_band * 0.8);
    \\        // Small hard glint.
    \\        float g = dot(n, normalize(kl + v));
    \\        float gw = max(fwidth(g), 1e-4);
    \\        col = mix(col, vec3(1.0), 0.75 * smoothstep(0.975 - gw, 0.975 + gw, g));
    \\        return col;
    \\    }
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
    \\layout(location = 3) in float a_highlight;
    \\uniform mat4 u_view;
    \\uniform mat4 u_proj;
    \\uniform float u_outline_k;
    \\uniform float u_select_k;
    \\out vec3 v_view_pos;
    \\flat out float v_highlight;
    \\flat out vec3 v_center;
    \\flat out float v_radius;
    \\flat out float v_outer;
    \\flat out vec4 v_color;
    \\void main() {
    \\    vec3 c = (u_view * vec4(a_center_radius.xyz, 1.0)).xyz;
    \\    float r = a_center_radius.w;
    \\    float d = length(c);
    \\    // Selected atoms get a wider ring (in the accent colour) even without outlines.
    \\    float ro = r + (a_highlight > 0.0 ? max(u_select_k, u_outline_k) : u_outline_k) * d;
    \\    v_highlight = a_highlight;
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
    \\flat in float v_highlight;
    \\uniform mat4 u_proj;
    \\uniform vec3 u_outline_color;
    \\uniform vec3 u_select_color;
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
    \\    // Kurzgesagt mode: the outline is a deep shade of the atom's own colour.
    \\    vec3 edge = u_cel == 2 ? mix(u_outline_color, v_color.rgb, 0.22) : u_outline_color;
    \\    vec3 ring = v_highlight > 0.0 ? u_select_color : edge;
    \\    o_color = vec4(mix(ring, body, k), v_color.a * cover);
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

/// Soft additive halo behind each atom (Kurzgesagt theme). Uses the sphere
/// VAO; drawn before the atoms without depth so the atoms cover the centre.
pub const glow_vs =
    \\#version 330 core
    \\layout(location = 0) in vec2 a_corner;
    \\layout(location = 1) in vec4 a_center_radius;
    \\layout(location = 2) in vec4 a_color;
    \\uniform mat4 u_view;
    \\uniform mat4 u_proj;
    \\uniform float u_glow_scale;
    \\out vec2 v_uv;
    \\flat out vec3 v_color;
    \\void main() {
    \\    vec3 c = (u_view * vec4(a_center_radius.xyz, 1.0)).xyz;
    \\    float s = a_center_radius.w * u_glow_scale;
    \\    v_uv = a_corner * u_glow_scale;
    \\    v_color = a_color.rgb;
    \\    gl_Position = u_proj * vec4(c + vec3(a_corner * s, 0.0), 1.0);
    \\}
;

pub const glow_fs =
    \\#version 330 core
    \\in vec2 v_uv;
    \\flat in vec3 v_color;
    \\uniform float u_glow_scale;
    \\uniform float u_glow_strength;
    \\out vec4 o_color;
    \\void main() {
    \\    // Distance in atom radii: 1 = the sphere's edge.
    \\    float r = length(v_uv);
    \\    float t = clamp((r - 0.9) / (u_glow_scale - 0.9), 0.0, 1.0);
    \\    float a = (1.0 - t) * (1.0 - t) * (1.0 - t);
    \\    o_color = vec4(v_color * a * u_glow_strength, 1.0);
    \\}
;

/// Full-screen night sky: a radial indigo gradient with procedural stars.
/// Drawn with an attribute-less VAO (positions from gl_VertexID).
pub const sky_vs =
    \\#version 330 core
    \\void main() {
    \\    vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
    \\    gl_Position = vec4(p * 2.0 - 1.0, 1.0, 1.0);
    \\}
;

pub const sky_fs =
    \\#version 330 core
    \\uniform vec2 u_resolution;
    \\uniform float u_star_px;
    \\uniform vec3 u_sky_center;
    \\uniform vec3 u_sky_edge;
    \\out vec4 o_color;
    \\float hash(vec2 p) {
    \\    p = fract(p * vec2(123.34, 456.21));
    \\    p += dot(p, p + 45.32);
    \\    return fract(p.x * p.y);
    \\}
    \\// One star cell of a layer on a grid of `cell` pixels.
    \\vec3 star(vec2 px, vec2 g, float cell, float chance, float size, float seed) {
    \\    float h = hash(g + seed);
    \\    if (h > chance) return vec3(0.0);
    \\    vec2 o = vec2(hash(g + seed + 7.1), hash(g + seed + 3.7)) * 0.7 + 0.15;
    \\    vec2 dd = abs(px - (g + o) * cell);
    \\    float d = length(dd);
    \\    float b = hash(g + seed + 1.3);
    \\    float core = 1.0 - smoothstep(size * 0.5, size * 0.5 + 1.0, d);
    \\    float halo = exp(-d * d / (size * size * 6.0)) * 0.35;
    \\    // The brightest big stars get a four-point flare.
    \\    float flare = b > 0.8 && size > 2.0
    \\        ? (exp(-dd.y / (0.35 * size)) * exp(-dd.x / (6.0 * size))
    \\         + exp(-dd.x / (0.35 * size)) * exp(-dd.y / (6.0 * size))) * 0.6
    \\        : 0.0;
    \\    // Mostly blue-white, a few warm or pink ones.
    \\    vec3 tint = b < 0.15 ? vec3(1.0, 0.62, 0.35) : b < 0.3 ? vec3(1.0, 0.5, 0.85) : vec3(0.55, 0.75, 1.0);
    \\    return mix(tint, vec3(1.0), core * 0.6) * (core + halo + flare) * (0.35 + 0.65 * b);
    \\}
    \\// A layer of stars; `chance` of a star per cell. Neighbouring cells are
    \\// included so halos and flares aren't clipped at cell edges.
    \\vec3 stars(vec2 px, float cell, float chance, float size, float seed) {
    \\    vec2 g = floor(px / cell);
    \\    vec3 sum = vec3(0.0);
    \\    for (int y = -1; y <= 1; y++)
    \\        for (int x = -1; x <= 1; x++)
    \\            sum += star(px, g + vec2(x, y), cell, chance, size, seed);
    \\    return sum;
    \\}
    \\void main() {
    \\    vec2 px = gl_FragCoord.xy;
    \\    vec2 uv = px / u_resolution;
    \\    vec2 q = (uv - vec2(0.5, 0.45)) * vec2(u_resolution.x / u_resolution.y, 1.0);
    \\    float r = clamp(length(q) / 0.95, 0.0, 1.0);
    \\    vec3 col = mix(u_sky_center, u_sky_edge, r * r * (3.0 - 2.0 * r));
    \\    float s = u_star_px;
    \\    col += stars(px, 11.0 * s, 0.05, 1.0 * s, 0.0) * 0.4;
    \\    col += stars(px, 37.0 * s, 0.14, 1.6 * s, 17.0) * 0.8;
    \\    col += stars(px, 140.0 * s, 0.30, 3.0 * s, 41.0);
    \\    // Dither to hide banding in the dark gradient.
    \\    col += (hash(px) - 0.5) / 255.0;
    \\    o_color = vec4(col, 1.0);
    \\}
;
