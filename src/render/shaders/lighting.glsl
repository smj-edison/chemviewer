// Cel bands and the flat style's depth fade (sphere.frag, cylinder.frag).

// Flat mode: farther objects fade toward the background, like the
// washed-out molecules behind the foreground in Kurzgesagt scenes.
vec3 fogged(vec3 c, float depth) {
    if (u_cel != 2) return c;
    float t = clamp((depth - u_fog_range.x) / max(u_fog_range.y - u_fog_range.x, 1e-4), 0.0, 1.0);
    return mix(c, u_fog_color, u_fog_amount * smoothstep(0.25, 1.0, t));
}

vec3 shade(vec3 base, vec3 n, vec3 v) {
    if (u_cel == 2) return base;
    if (u_cel == 3) {
        // Aero: glossy plastic/glass under a bright sky light.
        vec3 l = normalize(vec3(-0.3, 0.6, 0.75));
        float diff = max(dot(n, l), 0.0);
        float spec = pow(max(dot(n, normalize(l + v)), 0.0), 90.0);
        float fres = pow(1.0 - max(dot(n, v), 0.0), 2.5);
        vec3 c = base * (0.55 + 0.5 * diff);
        c += base * 0.35 * smoothstep(-0.2, -0.9, n.y); // bounce light from below
        c = mix(c, vec3(0.88, 0.97, 1.0), fres * 0.6);
        return c + vec3(spec) * 0.9;
    }
    // Cel: three flat bands with anti-aliased steps.
    vec3 l = normalize(vec3(0.35, 0.45, 1.0));
    float diff = max(dot(n, l), 0.0);
    float w = max(fwidth(diff), 1e-4);
    float band = 0.66
        + 0.17 * smoothstep(0.20 - w, 0.20 + w, diff)
        + 0.17 * smoothstep(0.62 - w, 0.62 + w, diff);
    return base * band;
}
