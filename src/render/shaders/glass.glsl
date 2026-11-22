// Liquid glass (u_cel == 4, experimental): atoms and bonds as tinted glass
// that refracts the backdrop behind them, with a bright specular rim on the
// side facing the light and a softer caustic glow on the far side.
//
// Atoms and bonds (u_glass_scene = 1) are translucent: they refract a copy
// of the scene drawn so far (binding 2), which holds the backdrop and all
// the glass behind them (Renderer.GlassLayers draws them in layers with a
// fresh copy before each). Faint, alpha-blended contacts are drawn before
// any glass and see only the backdrop cache (binding 1; with the pattern
// off it holds the plain background).

layout(set = 0, binding = 1) uniform sampler2D u_backdrop;
layout(set = 0, binding = 2) uniform sampler2D u_scene;

// What lies behind, seen along view-space point `q` (projected to the
// screen). The scene copy has row 0 at the top (the scene viewport is
// flipped); the backdrop cache has it at the bottom.
vec3 backdropAt(vec3 q) {
    vec4 c = u_proj * vec4(q, 1.0);
    vec2 ndc = c.xy / c.w;
    if (u_glass_scene == 1) return texture(u_scene, clamp(vec2(0.5 + 0.5 * ndc.x, 0.5 - 0.5 * ndc.y), 0.0, 1.0)).rgb;
    return texture(u_backdrop, clamp(ndc * 0.5 + 0.5, 0.0, 1.0)).rgb;
}

// `base`: tint (element or bond colour); `n`: view-space normal; `p`:
// view-space surface point; `thick`: path length through the object;
// `gloss`: strength of the highlights (thin bonds want less).
vec3 glass(vec3 base, vec3 n, vec3 p, float thick, float gloss) {
    vec3 d = normalize(p);
    float ndv = clamp(dot(n, -d), 0.0, 1.0);
    // Refraction: bend the ray at the surface and follow it a little past
    // the object, so the backdrop is magnified and flipped like a lens. One
    // index per channel gives a hint of dispersion at the edges.
    float reach = thick * 2.0 + 0.4;
    vec3 col;
    col.r = backdropAt(p + refract(d, n, 1.0 / 1.40) * reach).r;
    col.g = backdropAt(p + refract(d, n, 1.0 / 1.46) * reach).g;
    col.b = backdropAt(p + refract(d, n, 1.0 / 1.53) * reach).b;
    // Light frost: average with a slightly wider sample.
    col = mix(col, backdropAt(p + refract(d, n, 1.0 / 1.46) * reach * 1.4), 0.3);
    float lum = dot(col, vec3(0.2126, 0.7152, 0.0722));

    // Coloured glass filters what is behind it, more where it is thicker
    // (centre of the disc), so tints stack where atoms overlap. It also
    // scatters some of its own colour back, more over dark backdrops, where
    // filtering alone would leave it black.
    vec3 absorb = mix(vec3(1.0), base, 0.45 + 0.4 * ndv);
    col = mix(col * absorb, base, mix(0.35, 0.08, lum));

    // Near the silhouette the ray bends far off and the glass looks darker
    // (total internal reflection): a soft band just inside the rim.
    float edge = 1.0 - ndv;
    col *= 1.0 - 0.22 * smoothstep(0.45, 0.85, edge) * (1.0 - smoothstep(0.88, 0.99, edge));

    // Fresnel reflection of a bright, slightly cool sky.
    float f = 0.04 + 0.96 * pow(edge, 5.0);
    col = mix(col, vec3(0.97, 0.98, 1.0), f * 0.6 * gloss);

    vec3 l = normalize(vec3(-0.45, 0.6, 0.9));
    vec2 l2 = normalize(l.xy);
    float side = dot(n.xy / max(length(n.xy), 1e-4), l2);
    // Radial position on the disc (0 centre, 1 silhouette): bands in it
    // keep a steady width on screen, unlike bands in n.v.
    float rr = length(n.xy);
    // A crisp line along the edge over a faint, wider glow.
    float rim = smoothstep(0.90, 0.985, rr) * 0.9 + smoothstep(0.65, 1.0, rr) * 0.2;
    // Bright on the lit side, tinted opposite it, where light that passed
    // through the glass collects.
    col += vec3(1.0) * rim * smoothstep(-0.2, 0.8, side) * gloss;
    col += mix(base, vec3(1.0), 0.6) * rim * smoothstep(-0.1, 0.9, -side) * 0.6 * gloss;
    // Soft gloss: a broad, faint sheen and a smaller bright core.
    vec3 h = normalize(l - d);
    float nh = max(dot(n, h), 0.0);
    col += vec3(1.0) * (0.18 * pow(nh, 12.0) + 0.55 * smoothstep(0.86, 0.97, pow(nh, 30.0))) * gloss;
    return min(col, vec3(1.0));
}
