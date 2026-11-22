//! GLSL 330 core shaders.
//!
//! Shading modes (u_cel): 1 = cel/toon (flat bands, outlines), 2 = flat,
//! inspired by Kurzgesagt (one solid colour per object, highlight dots on
//! atoms, depth shown by fading toward the background, flat offset drop
//! shadows, no outlines). Outlines have a constant screen width:
//! `u_outline_k` is the outline width in world units per unit of view depth.

const lighting =
    \\uniform int u_cel;
    \\uniform vec3 u_fog_color;
    \\uniform vec2 u_fog_range;
    \\uniform float u_fog_amount;
    \\uniform float u_shadow_pass;
    \\uniform vec3 u_shadow_color;
    \\// Flat mode: farther objects fade toward the background, like the
    \\// washed-out molecules behind the foreground in Kurzgesagt scenes.
    \\vec3 fogged(vec3 c, float depth) {
    \\    if (u_cel != 2) return c;
    \\    float t = clamp((depth - u_fog_range.x) / max(u_fog_range.y - u_fog_range.x, 1e-4), 0.0, 1.0);
    \\    return mix(c, u_fog_color, u_fog_amount * smoothstep(0.25, 1.0, t));
    \\}
    \\vec3 shade(vec3 base, vec3 n, vec3 v) {
    \\    if (u_cel == 2) return base;
    \\    // Cel: three flat bands with anti-aliased steps.
    \\    vec3 l = normalize(vec3(0.35, 0.45, 1.0));
    \\    float diff = max(dot(n, l), 0.0);
    \\    float w = max(fwidth(diff), 1e-4);
    \\    float band = 0.66
    \\        + 0.17 * smoothstep(0.20 - w, 0.20 + w, diff)
    \\        + 0.17 * smoothstep(0.62 - w, 0.62 + w, diff);
    \\    return base * band;
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
    \\uniform vec2 u_shadow_offset;
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
    \\    gl_Position.xy += u_shadow_offset * gl_Position.w;
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
    \\    if (u_cel == 2) {
    \\        // Lighter dots of the same hue, up and to the right: a big one
    \\        // and a small one. Placed on the disc (n.xy), so they scale
    \\        // with the atom and stay put as the view rotates.
    \\        vec2 q = n.xy;
    \\        // Clamped: at the silhouette the derivatives blow up and would
    \\        // smear the dots into a pale rim.
    \\        float aa = min(max(fwidth(q.x), fwidth(q.y)), 0.06);
    \\        float dots = min(length(q - vec2(0.12, 0.14)) - 0.30, length(q - vec2(0.52, 0.12)) - 0.13);
    \\        body = mix(body, mix(body, vec3(1.0), 0.32), 1.0 - smoothstep(-aa, aa, dots));
    \\        body = fogged(body, -p.z);
    \\    }
    \\    float k = 1.0;
    \\    if (v_outer > v_radius) k = clamp(disc_i / max(fwidth(disc_i), 1e-9) + 0.5, 0.0, 1.0);
    \\    vec4 clip = u_proj * vec4(p, 1.0);
    \\    gl_FragDepth = clip.z / clip.w * 0.5 + 0.5;
    \\    // Outer edge coverage drives alpha-to-coverage for smooth silhouettes.
    \\    float cover = clamp(disc_o / max(fwidth(disc_o), 1e-9), 0.0, 1.0);
    \\    // Kurzgesagt mode: the outline is a deep shade of the atom's own colour.
    \\    vec3 edge = u_outline_color;
    \\    vec3 ring = v_highlight > 0.0 ? u_select_color : edge;
    \\    o_color = vec4(mix(ring, body, k), v_color.a * cover);
    \\    if (u_shadow_pass > 0.5) {
    \\        // Multiply factor (blended with DST_COLOR), at one fixed depth.
    \\        // Edge coverage goes to alpha-to-coverage (alpha is not blended).
    \\        o_color = vec4(u_shadow_color, cover);
    \\        gl_FragDepth = 0.999999;
    \\    }
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
    \\uniform vec2 u_shadow_offset;
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
    \\    gl_Position.xy += u_shadow_offset * gl_Position.w;
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
    \\        gl_FragDepth = gl_FragCoord.z;
    \\        return;
    \\    }
    \\    if (u_shadow_pass > 0.5) {
    \\        o_color = vec4(u_shadow_color, 1.0);
    \\        gl_FragDepth = 0.999999;
    \\        return;
    \\    }
    \\    gl_FragDepth = gl_FragCoord.z;
    \\    vec4 c = v_t < 0.5 ? v_ca : v_cb;
    \\    vec3 col = shade(c.rgb, normalize(v_normal), normalize(-v_view_pos));
    \\    o_color = vec4(fogged(col, -v_view_pos.z), c.a);
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

/// Full-screen background pattern, drawn right after the clear. Each layer
/// lives on a large sphere around a fixed world anchor (`u_anchor`, set when
/// the view is fitted), so it turns with the camera and, being nearer or
/// farther, shifts at its own rate when panning and zooming (parallax).
///
/// u_mode 1: faint rings and dots (cel style).
/// u_mode 2: flat style "cells", as if seen through a macro lens with a
///   shallow depth of field: big blurred cells with a membrane rim and a
///   nucleus, sharper small ones nearer, drifting vesicles.
/// u_mode 3: flat style "space", equally out of focus: nebula haze, glowing
///   bokeh discs and a few four-point sparkle stars.
pub const background_vs =
    \\#version 330 core
    \\out vec2 v_ndc;
    \\void main() {
    \\    vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2) * 2.0 - 1.0;
    \\    v_ndc = p;
    \\    gl_Position = vec4(p, 0.0, 1.0);
    \\}
;

pub const background_fs =
    \\#version 330 core
    \\in vec2 v_ndc;
    \\out vec4 o_color;
    \\uniform mat4 u_view;
    \\uniform vec2 u_tan;        // tan(fovy/2) * aspect, tan(fovy/2)
    \\uniform float u_px;        // view-plane units per framebuffer pixel
    \\uniform vec3 u_anchor;     // world anchor of the pattern shells
    \\uniform float u_radius;    // scene radius at fit time
    \\uniform int u_mode;
    \\uniform vec3 u_bg;
    \\uniform vec3 u_ink;        // main tone
    \\uniform vec3 u_deep;       // stronger tone (rims, nuclei)
    \\uniform vec3 u_light;      // tone on the other side of the background
    \\uniform vec3 u_glow_a;
    \\uniform vec3 u_glow_b;
    \\uniform float u_coc_px;    // lens blur scale, framebuffer pixels
    \\
    \\vec4 hash4(vec3 p) {
    \\    vec4 q = vec4(dot(p, vec3(127.1, 311.7, 74.7)), dot(p, vec3(269.5, 183.3, 246.1)),
    \\                  dot(p, vec3(113.5, 271.9, 124.6)), dot(p, vec3(201.3, 97.1, 157.7)));
    \\    return fract(sin(q) * 43758.5453);
    \\}
    \\
    \\float noise(vec3 p) {
    \\    vec3 i = floor(p);
    \\    vec3 f = p - i;
    \\    f = f * f * (3.0 - 2.0 * f);
    \\    float n000 = hash4(i).x, n100 = hash4(i + vec3(1, 0, 0)).x;
    \\    float n010 = hash4(i + vec3(0, 1, 0)).x, n110 = hash4(i + vec3(1, 1, 0)).x;
    \\    float n001 = hash4(i + vec3(0, 0, 1)).x, n101 = hash4(i + vec3(1, 0, 1)).x;
    \\    float n011 = hash4(i + vec3(0, 1, 1)).x, n111 = hash4(i + vec3(1, 1, 1)).x;
    \\    return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
    \\               mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
    \\}
    \\
    \\vec3 cam_pos;
    \\vec3 ray_dir;
    \\
    \\float shellR(float shell) { return max(shell * u_radius, length(cam_pos - u_anchor) * 1.05); }
    \\
    \\// Where the view ray leaves a sphere of radius `shell` (in scene radii)
    \\// around the anchor; returned as a unit direction from the anchor.
    \\vec3 shellDir(float shell) {
    \\    vec3 oc = cam_pos - u_anchor;
    \\    float R = shellR(shell);
    \\    float b = dot(oc, ray_dir);
    \\    float c = dot(oc, oc) - R * R;
    \\    float t = -b + sqrt(max(b * b - c, 0.0));
    \\    return normalize(oc + ray_dir * t);
    \\}
    \\
    \\// Pixel footprint on a shell, in pattern units (for anti-aliasing).
    \\float footprint(float shell, float scale) {
    \\    float R = shellR(shell);
    \\    return u_px * (R + length(cam_pos - u_anchor)) / R * scale;
    \\}
    \\
    \\// Edge softness for a layer: one pixel of anti-aliasing plus depth of
    \\// field. The molecule (at the anchor) is in focus; a layer at distance
    \\// `dist` gets a circle of confusion proportional to 1 - focus / dist, so
    \\// zooming in (focus nearer) blurs the backdrop more, like a macro lens.
    \\// `k` scales it per layer (sparkle stars stay readable).
    \\float dof(float shell, float scale, float k) {
    \\    float focus = length(cam_pos - u_anchor);
    \\    float dist = shellR(shell) + focus;
    \\    return footprint(shell, scale) * (1.0 + u_coc_px * k * (1.0 - focus / dist));
    \\}
    \\
    \\// Features (below) sit on a jittered 3D lattice, sliced by the unit sphere. Centres
    \\// sit in the middle half of their cell, so anything reaching less than
    \\// 0.75 cells is covered by the 2x2x2 cells on the point's near side.
    \\// Those are visited in ascending lattice order, so overlapping
    \\// translucent features composite in the same order everywhere (no seams).
    \\
    \\// Plain discs or rings (light/dark themes).
    \\vec3 dots(vec3 col, vec3 p, float density, vec2 rad, float aa, float alpha, float seed, int ring,
    \\          vec3 ca, vec3 cb) {
    \\    vec3 cell_ = floor(p);
    \\    vec3 base_ = cell_ - 1.0 + step(0.5, p - cell_);
    \\    for (int i_ = 0; i_ < 8; i_++) {
    \\        vec3 g_ = base_ + vec3(i_ & 1, (i_ >> 1) & 1, (i_ >> 2) & 1);
    \\        vec4 h = hash4(g_ + seed);
    \\        vec3 c = g_ + 0.25 + 0.5 * h.xyz;
    \\        if (h.w > density) continue;
    \\        float r = mix(rad.x, rad.y, fract(h.w * 17.0 / density));
    \\        aa = min(aa, 0.7 - r); // stay inside the 2x2x2 search
    \\        float d = length(p - c);
    \\        if (d >= r + max(0.11 * r, aa) + aa) continue; // out of reach: skip the shading
    \\        float a = ring == 1
    \\            ? 1.0 - smoothstep(max(0.11 * r, aa) - aa, max(0.11 * r, aa) + aa, abs(d - r))
    \\            : 1.0 - smoothstep(r - aa, r + aa, d);
    \\        col = mix(col, fract(h.x * 7.0 + h.z * 3.0) < 0.7 ? ca : cb, a * alpha);
    \\    }
    \\    return col;
    \\}
    \\
    \\// Out-of-focus cells: body, a darker membrane just inside the edge, and
    \\// an off-centre nucleus. `blur` is the defocus as a fraction of radius.
    \\vec3 cells(vec3 col, vec3 p, float density, vec2 rad, float blur, float aa, float alpha, float seed) {
    \\    vec3 cell_ = floor(p);
    \\    vec3 base_ = cell_ - 1.0 + step(0.5, p - cell_);
    \\    for (int i_ = 0; i_ < 8; i_++) {
    \\        vec3 g_ = base_ + vec3(i_ & 1, (i_ >> 1) & 1, (i_ >> 2) & 1);
    \\        vec4 h = hash4(g_ + seed);
    \\        vec3 c = g_ + 0.25 + 0.5 * h.xyz;
    \\        if (h.w > density) continue;
    \\        float r = mix(rad.x, rad.y, fract(h.w * 17.0 / density));
    \\        float e = min(blur + aa / r, 0.7 / r - 1.0); // stay inside the 2x2x2 search
    \\        float u = length(p - c) / r;
    \\        // Out of reach of the body and of the (off-centre, blurred) nucleus.
    \\        if (u >= max(1.0 + e, 0.75 + 0.9 * e)) continue;
    \\        float body = 1.0 - smoothstep(1.0 - e, 1.0 + e, u);
    \\        float rim = body * (1.0 - smoothstep(0.0, 0.08 + e, abs(u - 0.90)));
    \\        vec3 nc = c + (fract(h.yzx * 13.0) - 0.5) * 0.45 * r;
    \\        float nu = length(p - nc) / (0.36 * r);
    \\        float nucleus = 1.0 - smoothstep(1.0 - 2.5 * e, 1.0 + 2.5 * e, nu);
    \\        col = mix(col, u_ink, body * alpha);
    \\        col = mix(col, u_deep, rim * alpha * 0.55);
    \\        col = mix(col, u_deep, nucleus * alpha * 0.75);
    \\        // A soft highlight on the upper left, as on Kurzgesagt's blobs.
    \\        vec3 hc = c + vec3(-0.35, 0.40, 0.0) * r;
    \\        float hl = 1.0 - smoothstep(0.0, 0.45 + e, length(p - hc) / r);
    \\        col = mix(col, u_light, hl * body * alpha * 0.35);
    \\    }
    \\    return col;
    \\}
    \\
    \\// Bokeh: soft glowing discs, a little brighter toward the rim.
    \\vec3 bokeh(vec3 col, vec3 p, float density, vec2 rad, float blur, float aa, float alpha, float seed) {
    \\    vec3 cell_ = floor(p);
    \\    vec3 base_ = cell_ - 1.0 + step(0.5, p - cell_);
    \\    for (int i_ = 0; i_ < 8; i_++) {
    \\        vec3 g_ = base_ + vec3(i_ & 1, (i_ >> 1) & 1, (i_ >> 2) & 1);
    \\        vec4 h = hash4(g_ + seed);
    \\        vec3 c = g_ + 0.25 + 0.5 * h.xyz;
    \\        if (h.w > density) continue;
    \\        float r = mix(rad.x, rad.y, fract(h.w * 17.0 / density));
    \\        float e = min(blur + aa / r, 0.7 / r - 1.0); // stay inside the 2x2x2 search
    \\        float u = length(p - c) / r;
    \\        if (u >= 1.0 + e) continue;
    \\        float a = (1.0 - smoothstep(1.0 - e, 1.0 + e, u)) * (0.7 + 0.3 * smoothstep(0.3, 0.95, u));
    \\        float k = fract(h.x * 5.0 + h.y * 3.0);
    \\        vec3 tone = k < 0.4 ? u_glow_a : k < 0.8 ? u_glow_b : u_light;
    \\        col = mix(col, tone, a * alpha);
    \\    }
    \\    return col;
    \\}
    \\
    \\// Four-point sparkle stars with a round core.
    \\vec3 stars(vec3 col, vec3 p, float density, vec2 rad, float aa, float alpha, float seed) {
    \\    vec3 cell_ = floor(p);
    \\    vec3 base_ = cell_ - 1.0 + step(0.5, p - cell_);
    \\    for (int i_ = 0; i_ < 8; i_++) {
    \\        vec3 g_ = base_ + vec3(i_ & 1, (i_ >> 1) & 1, (i_ >> 2) & 1);
    \\        vec4 h = hash4(g_ + seed);
    \\        vec3 c = g_ + 0.25 + 0.5 * h.xyz;
    \\        if (h.w > density) continue;
    \\        float r = mix(rad.x, rad.y, fract(h.w * 17.0 / density));
    \\        vec3 n = normalize(c);
    \\        c = n * length(p); // on the sphere, so the flat star is not sliced at an angle
    \\        vec3 t1 = normalize(cross(n, abs(n.y) < 0.9 ? vec3(0, 1, 0) : vec3(1, 0, 0)));
    \\        vec3 t2 = cross(n, t1);
    \\        vec2 q = vec2(dot(p - c, t1), dot(p - c, t2)) / r;
    \\        float w = aa / r;
    \\        float core = 1.0 - smoothstep(0.22 - w, 0.22 + w, length(q));
    \\        float arms = max(1.0 - smoothstep(0.0, 0.07 + w, abs(q.x) * (0.6 + abs(q.y) * 3.0)),
    \\                         1.0 - smoothstep(0.0, 0.07 + w, abs(q.y) * (0.6 + abs(q.x) * 3.0)));
    \\        arms *= 1.0 - smoothstep(0.4, 1.0, length(q));
    \\        float k = fract(h.x * 5.0 + h.y * 3.0);
    \\        vec3 tone = k < 0.6 ? u_light : k < 0.8 ? u_glow_a : u_glow_b;
    \\        col = mix(col, tone, max(core, arms) * alpha);
    \\    }
    \\    return col;
    \\}
    \\
    \\void main() {
    \\    mat3 R = mat3(u_view);
    \\    mat3 Rt = transpose(R);
    \\    cam_pos = -(Rt * u_view[3].xyz);
    \\    ray_dir = normalize(Rt * normalize(vec3(v_ndc * u_tan, -1.0)));
    \\    vec3 col = u_bg;
    \\    float vig = smoothstep(0.4, 1.6, length(v_ndc));
    \\    if (u_mode == 2) {
    \\        col = mix(col, u_ink, 0.25 * vig);
    \\        // Far: big, heavily defocused cells.
    \\        float s1 = 2.6;
    \\        col = cells(col, shellDir(11.0) * s1, 0.55, vec2(0.26, 0.48), 0.10, dof(11.0, s1, 1.0), 0.55, 3.0);
    \\        // Middle: smaller cells, less blurred.
    \\        float s2 = 6.0;
    \\        col = cells(col, shellDir(7.0) * s2, 0.30, vec2(0.16, 0.30), 0.03, dof(7.0, s2, 1.0), 0.45, 11.0);
    \\        // Near: drifting vesicles, soft.
    \\        float s3 = 16.0;
    \\        col = dots(col, shellDir(4.8) * s3, 0.22, vec2(0.05, 0.11), dof(4.8, s3, 1.0), 0.40, 29.0, 0, u_deep, u_light);
    \\    } else if (u_mode == 3) {
    \\        // Nebula haze: slow noise, tinted toward the two glow colours.
    \\        vec3 hd = shellDir(14.0);
    \\        float n1 = noise(hd * 2.2) * 0.6 + noise(hd * 4.7 + 7.0) * 0.4;
    \\        float n2 = noise(hd * 1.8 + 31.0);
    \\        float haze = smoothstep(0.45, 0.85, n1);
    \\        col = mix(col, mix(u_glow_a, u_glow_b, n2), haze * 0.22);
    \\        col = mix(col, u_ink, 0.35 * vig);
    \\        // Far: big defocused bokeh.
    \\        float s1 = 3.0;
    \\        col = bokeh(col, shellDir(11.0) * s1, 0.45, vec2(0.18, 0.40), 0.08, dof(11.0, s1, 1.0), 0.20, 5.0);
    \\        // Middle: small soft glows.
    \\        float s2 = 9.0;
    \\        col = bokeh(col, shellDir(7.0) * s2, 0.30, vec2(0.07, 0.15), 0.08, dof(7.0, s2, 1.0), 0.28, 13.0);
    \\        // Near: a few sparkle stars, and a dusting of tiny ones farther off.
    \\        float s3 = 7.0;
    \\        col = stars(col, shellDir(5.0) * s3, 0.07, vec2(0.16, 0.30), dof(5.0, s3, 0.25), 0.45, 23.0);
    \\        float s4 = 30.0;
    \\        col = dots(col, shellDir(9.0) * s4, 0.25, vec2(0.04, 0.08), dof(9.0, s4, 0.5), 0.35, 37.0, 0, u_light, u_glow_b);
    \\    } else if (u_mode == 1) {
    \\        // Cel style is crisp: no depth of field.
    \\        float s1 = 9.0;
    \\        col = dots(col, shellDir(7.0) * s1, 0.30, vec2(0.10, 0.22), dof(7.0, s1, 0.0), 0.40, 5.0, 1, u_ink, u_light);
    \\        float s2 = 22.0;
    \\        col = dots(col, shellDir(5.0) * s2, 0.30, vec2(0.05, 0.09), dof(5.0, s2, 0.0), 0.40, 17.0, 0, u_ink, u_light);
    \\    }
    \\    o_color = vec4(col, 1.0);
    \\}
;

/// Upsamples the cached backdrop (`background_fs`, rendered at reduced
/// resolution into a half-float texture) to the framebuffer.
pub const background_blit_fs =
    \\#version 330 core
    \\in vec2 v_ndc;
    \\out vec4 o_color;
    \\uniform sampler2D u_tex;
    \\void main() {
    \\    vec3 col = texture(u_tex, v_ndc * 0.5 + 0.5).rgb;
    \\    // Dither (about +/-0.5/255) so soft gradients do not band; interleaved
    \\    // gradient noise (Jimenez 2014) is cheaper than a sin hash.
    \\    float dn = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))));
    \\    o_color = vec4(col + (dn - 0.5) / 255.0, 1.0);
    \\}
;
