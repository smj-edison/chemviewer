#version 450
// Liquid glass: each atom's blob is the smooth union of its sphere, its
// bonds (capsules) and its bonded neighbours' spheres, so bonds flow into
// the atoms. The blob only draws the part of the surface on its own side of
// each bond (a plane across the gap between the two atoms); the neighbour
// draws the rest from the same field, so the union is seamless.
//
// The smooth union is the exponential one (log-sum-exp), which unlike the
// polynomial smin doesn't depend on the order primitives are combined in:
// both sides of a bond evaluate the same field near their shared plane.
// Each bond has a weight (0..1, Renderer `Style.liquidWeight`): a pair of
// primitives blends by the smaller of their weights (the atom's own sphere
// has 1), so a bond that has just formed meets its atoms with a hard join,
// and its neck grows as the bond strengthens. That pairing makes the sum
// depend on which primitive is nearest, so it takes two passes.
// Ray-marched in world space; shaded by glass.glsl.
#include "common.glsl"
#include "lighting.glsl"
#include "glass.glsl"

struct Link {
    vec4 other;        // neighbour centre (world), its radius
    vec4 bond_color;   // this side's bond colour
    vec4 other_color;  // neighbour's atom colour
    vec4 params;       // bond radius, plane offset from this atom along the bond, weight, -
};
layout(std430, set = 0, binding = 3) readonly buffer Links { Link links[]; };

layout(location = 0) in vec3 v_view_pos;
layout(location = 1) flat in vec4 v_center_radius;
layout(location = 2) flat in vec4 v_color;
layout(location = 3) flat in vec2 v_bound_highlight;
layout(location = 4) flat in uvec2 v_links;

layout(location = 0) out vec4 o_color;

float sdCapsule(vec3 p, vec3 a, vec3 b, float r) {
    vec3 pa = p - a;
    vec3 ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h) - r;
}

// Weighted log-sum-exp over the blob's primitives: d = m - k ln S, with m
// the nearest distance and S = sum of w_i exp(-(d_i - m) / k), where w_i is
// 1 for the nearest primitive and otherwise the smaller of its weight and
// the nearest one's. Colour and radius are averaged with the same weights.
struct Acc { float m; float wm; vec3 cm; float rm; float s; vec3 col; float rad; };

void nearest(inout Acc a, float d, float w, vec3 col, float rad) {
    if (d < a.m) {
        a.m = d;
        a.wm = w;
        a.cm = col;
        a.rm = rad;
    }
}

void add(inout Acc a, float d, float w, vec3 col, float rad) {
    float e = min(w, a.wm) * exp((a.m - d) / u_liquid_k);
    a.s += e;
    a.col += col * e;
    a.rad += rad * e;
}

Acc field(vec3 p) {
    vec3 c = v_center_radius.xyz;
    uint end = v_links.x + v_links.y;
    Acc a = Acc(1e9, 1.0, vec3(0.0), 0.0, 0.0, vec3(0.0), 0.0);
    float d0 = length(p - c) - v_center_radius.w;
    nearest(a, d0, 1.0, v_color.rgb, v_center_radius.w);
    for (uint i = v_links.x; i < end; i++) {
        Link l = links[i];
        nearest(a, sdCapsule(p, c, l.other.xyz, l.params.x), l.params.z, l.bond_color.rgb, l.params.x);
        nearest(a, length(p - l.other.xyz) - l.other.w, l.params.z, l.other_color.rgb, l.other.w);
    }
    add(a, d0, 1.0, v_color.rgb, v_center_radius.w);
    for (uint i = v_links.x; i < end; i++) {
        Link l = links[i];
        add(a, sdCapsule(p, c, l.other.xyz, l.params.x), l.params.z, l.bond_color.rgb, l.params.x);
        add(a, length(p - l.other.xyz) - l.other.w, l.params.z, l.other_color.rgb, l.other.w);
    }
    // The nearest primitive's own term came in with weight w_m: top it up
    // to 1.
    float top = 1.0 - a.wm;
    a.s += top;
    a.col += a.cm * top;
    a.rad += a.rm * top;
    return a;
}

float dist(Acc a) {
    return a.m - u_liquid_k * log(a.s);
}

float map(vec3 p) {
    return dist(field(p));
}

// How far `p` is inside this atom's side of all of its bonds (negative:
// on a neighbour's side, which draws it instead).
float ownership(vec3 p) {
    vec3 c = v_center_radius.xyz;
    float m = 1e9;
    for (uint i = v_links.x; i < v_links.x + v_links.y; i++) {
        Link l = links[i];
        vec3 u = normalize(l.other.xyz - c);
        m = min(m, l.params.y - dot(p - c, u));
    }
    return m;
}

// Ray `ro + t rd` against a sphere: entry t, or -1 if it misses.
float sphereEntry(vec3 ro, vec3 rd, vec3 c, float r) {
    vec3 oc = ro - c;
    float b = dot(oc, rd);
    float h = b * b - (dot(oc, oc) - r * r);
    return h < 0.0 ? -1.0 : -b - sqrt(h);
}

// Ray against a capsule (Inigo Quilez): entry t, or -1 if it misses.
float capsuleEntry(vec3 ro, vec3 rd, vec3 pa, vec3 pb, float r) {
    vec3 ba = pb - pa;
    vec3 oa = ro - pa;
    float baba = dot(ba, ba);
    float bard = dot(ba, rd);
    float baoa = dot(ba, oa);
    float rdoa = dot(rd, oa);
    float oaoa = dot(oa, oa);
    float a = baba - bard * bard;
    float b = baba * rdoa - baoa * bard;
    float c = baba * oaoa - baoa * baoa - r * r * baba;
    float h = b * b - a * c;
    if (h >= 0.0) {
        float t = (-b - sqrt(h)) / a;
        float y = baoa + t * bard;
        if (y > 0.0 && y < baba) return t;
        // Caps.
        vec3 oc = (y <= 0.0) ? oa : ro - pb;
        b = dot(rd, oc);
        c = dot(oc, oc) - r * r;
        h = b * b - c;
        if (h > 0.0) return -b - sqrt(h);
    }
    return -1.0;
}

// Ray-traced entry into the blob's primitives, each widened by the most the
// smooth union can swell the surface (k ln N for N primitives): the march
// starts there, and rays that enter none of them miss the blob.
float entry(vec3 ro, vec3 rd) {
    vec3 c = v_center_radius.xyz;
    float e = u_liquid_k * log(float(1u + 2u * v_links.y)) + 1e-3;
    float t = 1e9;
    float s = sphereEntry(ro, rd, c, v_center_radius.w + e);
    if (s > -1.0) t = s;
    for (uint i = v_links.x; i < v_links.x + v_links.y; i++) {
        Link l = links[i];
        float q = capsuleEntry(ro, rd, c, l.other.xyz, l.params.x + e);
        if (q > -1.0) t = min(t, q);
        q = sphereEntry(ro, rd, l.other.xyz, l.other.w + e);
        if (q > -1.0) t = min(t, q);
    }
    return t;
}

void main() {
    mat3 R = mat3(u_view);
    mat3 Rt = transpose(R);
    vec3 ro = -(Rt * u_view[3].xyz);
    vec3 dv = normalize(v_view_pos);
    vec3 rd = Rt * dv;

    // Bounding sphere.
    vec3 oc = ro - v_center_radius.xyz;
    float rb = v_bound_highlight.x;
    float b = dot(oc, rd);
    float h = b * b - (dot(oc, oc) - rb * rb);
    if (h < 0.0) discard;
    h = sqrt(h);
    float t1 = -b + h;
    float te = entry(ro, rd);
    if (te > t1) discard;
    float t = max(max(-b - h, te), 0.0);

    // Sphere tracing. Misses that pass within a pixel keep their closest
    // approach, for anti-aliased silhouettes (alpha-to-coverage).
    bool hit = false;
    float best = 1e9;
    float best_t = t;
    for (int i = 0; i < 64; i++) {
        float d = map(ro + rd * t);
        float px = max(t, 1e-3) * u_px_k;
        if (d < 0.5 * px) {
            hit = true;
            break;
        }
        if (d / px < best) {
            best = d / px;
            best_t = t;
        }
        t += d;
        if (t > t1) break;
    }
    float cover = 1.0;
    if (!hit) {
        if (best >= 1.0) discard;
        t = best_t;
        cover = 1.0 - smoothstep(0.0, 1.0, best);
    }
    vec3 p = ro + rd * t;
    float own = ownership(p);
    if (own < 0.0) discard;

    // Normal: tetrahedral gradient.
    float e = max(t * u_px_k * 0.5, 1e-4);
    const vec2 kk = vec2(1.0, -1.0);
    vec3 nw = normalize(kk.xyy * map(p + kk.xyy * e) + kk.yyx * map(p + kk.yyx * e) +
                        kk.yxy * map(p + kk.yxy * e) + kk.xxx * map(p + kk.xxx * e));
    Acc a = field(p);
    vec3 base = a.col / a.s;
    float rad = a.rad / a.s;

    vec3 pv = R * p + u_view[3].xyz;
    vec3 n = normalize(R * nw);
    // Refraction fades out toward the planes where a neighbour's blob takes
    // over: there both sides show what is straight behind them, so they
    // match. (Bent, the side drawn second would refract its neighbour's
    // glass beside it and show a tinted seam.)
    float bend = smoothstep(0.0, 0.12, own);
    vec3 body = glass(base, n, pv, 2.0 * rad * max(dot(n, -dv), 0.0), 1.0, bend);
    if (v_bound_highlight.y > 0.0) {
        // Selected: an accent band along the silhouette.
        body = mix(body, u_select_color, smoothstep(0.55, 0.85, 1.0 - max(dot(n, -dv), 0.0)));
    }
    vec4 clip = u_proj * vec4(pv, 1.0);
    gl_FragDepth = clip.z / clip.w * 0.5 + 0.5;
    o_color = vec4(body, cover);
}
