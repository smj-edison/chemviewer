#version 450
// Full-screen background pattern, rendered into the backdrop cache (see
// Renderer.updateBackground) and upsampled behind the scene. Each layer
// lives on a large sphere around a fixed world anchor (`u_anchor`, set when
// the view is fitted), so it turns with the camera and, being nearer or
// farther, shifts at its own rate when panning and zooming (parallax).
//
// The same backdrop sits behind both shadings, as if seen through a macro
// lens with a shallow depth of field:
// u_mode 0: "cells": big blurred cells with a membrane rim and a nucleus,
//   sharper small ones nearer, drifting vesicles.
// u_mode 1: "space": nebula haze, glowing bokeh discs and a few four-point
//   sparkle stars.
#include "common.glsl"

layout(location = 0) in vec2 v_ndc;
layout(location = 0) out vec4 o_color;

vec4 hash4(vec3 p) {
    vec4 q = vec4(dot(p, vec3(127.1, 311.7, 74.7)), dot(p, vec3(269.5, 183.3, 246.1)),
                  dot(p, vec3(113.5, 271.9, 124.6)), dot(p, vec3(201.3, 97.1, 157.7)));
    return fract(sin(q) * 43758.5453);
}

float noise(vec3 p) {
    vec3 i = floor(p);
    vec3 f = p - i;
    f = f * f * (3.0 - 2.0 * f);
    float n000 = hash4(i).x, n100 = hash4(i + vec3(1, 0, 0)).x;
    float n010 = hash4(i + vec3(0, 1, 0)).x, n110 = hash4(i + vec3(1, 1, 0)).x;
    float n001 = hash4(i + vec3(0, 0, 1)).x, n101 = hash4(i + vec3(1, 0, 1)).x;
    float n011 = hash4(i + vec3(0, 1, 1)).x, n111 = hash4(i + vec3(1, 1, 1)).x;
    return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
               mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
}

vec3 cam_pos;
vec3 ray_dir;

float shellR(float shell) { return max(shell * u_radius, length(cam_pos - u_anchor) * 1.05); }

// Where the view ray leaves a sphere of radius `shell` (in scene radii)
// around the anchor; returned as a unit direction from the anchor.
vec3 shellDir(float shell) {
    vec3 oc = cam_pos - u_anchor;
    float R = shellR(shell);
    float b = dot(oc, ray_dir);
    float c = dot(oc, oc) - R * R;
    float t = -b + sqrt(max(b * b - c, 0.0));
    return normalize(oc + ray_dir * t);
}

// Pixel footprint on a shell, in pattern units (for anti-aliasing).
float footprint(float shell, float scale) {
    float R = shellR(shell);
    return u_px * (R + length(cam_pos - u_anchor)) / R * scale;
}

// Edge softness for a layer: one pixel of anti-aliasing plus depth of
// field. The molecule (at the anchor) is in focus; a layer at distance
// `dist` gets a circle of confusion proportional to 1 - focus / dist, so
// zooming in (focus nearer) blurs the backdrop more, like a macro lens.
// `k` scales it per layer (sparkle stars stay readable).
float dof(float shell, float scale, float k) {
    float focus = length(cam_pos - u_anchor);
    float dist = shellR(shell) + focus;
    return footprint(shell, scale) * (1.0 + u_coc_px * k * (1.0 - focus / dist));
}

// Features (below) sit on a jittered 3D lattice, sliced by the unit sphere. Centres
// sit in the middle half of their cell, so anything reaching less than
// 0.75 cells is covered by the 2x2x2 cells on the point's near side.
// Those are visited in ascending lattice order, so overlapping
// translucent features composite in the same order everywhere (no seams).

// Plain discs (vesicles, dust).
vec3 dots(vec3 col, vec3 p, float density, vec2 rad, float aa, float alpha, float seed,
          vec3 ca, vec3 cb) {
    vec3 cell_ = floor(p);
    vec3 base_ = cell_ - 1.0 + step(0.5, p - cell_);
    for (int i_ = 0; i_ < 8; i_++) {
        vec3 g_ = base_ + vec3(i_ & 1, (i_ >> 1) & 1, (i_ >> 2) & 1);
        vec4 h = hash4(g_ + seed);
        vec3 c = g_ + 0.25 + 0.5 * h.xyz;
        if (h.w > density) continue;
        float r = mix(rad.x, rad.y, fract(h.w * 17.0 / density));
        aa = min(aa, 0.7 - r); // stay inside the 2x2x2 search
        float d = length(p - c);
        if (d >= r + aa) continue; // out of reach: skip the shading
        float a = 1.0 - smoothstep(r - aa, r + aa, d);
        col = mix(col, fract(h.x * 7.0 + h.z * 3.0) < 0.7 ? ca : cb, a * alpha);
    }
    return col;
}

// Out-of-focus cells: body, a darker membrane just inside the edge, and
// an off-centre nucleus. `blur` is the defocus as a fraction of radius.
vec3 cells(vec3 col, vec3 p, float density, vec2 rad, float blur, float aa, float alpha, float seed) {
    vec3 cell_ = floor(p);
    vec3 base_ = cell_ - 1.0 + step(0.5, p - cell_);
    for (int i_ = 0; i_ < 8; i_++) {
        vec3 g_ = base_ + vec3(i_ & 1, (i_ >> 1) & 1, (i_ >> 2) & 1);
        vec4 h = hash4(g_ + seed);
        vec3 c = g_ + 0.25 + 0.5 * h.xyz;
        if (h.w > density) continue;
        float r = mix(rad.x, rad.y, fract(h.w * 17.0 / density));
        float e = min(blur + aa / r, 0.7 / r - 1.0); // stay inside the 2x2x2 search
        float u = length(p - c) / r;
        // Out of reach of the body and of the (off-centre, blurred) nucleus.
        if (u >= max(1.0 + e, 0.75 + 0.9 * e)) continue;
        float body = 1.0 - smoothstep(1.0 - e, 1.0 + e, u);
        float rim = body * (1.0 - smoothstep(0.0, 0.08 + e, abs(u - 0.90)));
        vec3 nc = c + (fract(h.yzx * 13.0) - 0.5) * 0.45 * r;
        float nu = length(p - nc) / (0.36 * r);
        float nucleus = 1.0 - smoothstep(1.0 - 2.5 * e, 1.0 + 2.5 * e, nu);
        col = mix(col, u_ink, body * alpha);
        col = mix(col, u_deep, rim * alpha * 0.55);
        col = mix(col, u_deep, nucleus * alpha * 0.75);
        // A soft highlight on the upper left, as on Kurzgesagt's blobs.
        vec3 hc = c + vec3(-0.35, 0.40, 0.0) * r;
        float hl = 1.0 - smoothstep(0.0, 0.45 + e, length(p - hc) / r);
        col = mix(col, u_light, hl * body * alpha * 0.35);
    }
    return col;
}

// Bokeh: soft glowing discs, a little brighter toward the rim.
vec3 bokeh(vec3 col, vec3 p, float density, vec2 rad, float blur, float aa, float alpha, float seed) {
    vec3 cell_ = floor(p);
    vec3 base_ = cell_ - 1.0 + step(0.5, p - cell_);
    for (int i_ = 0; i_ < 8; i_++) {
        vec3 g_ = base_ + vec3(i_ & 1, (i_ >> 1) & 1, (i_ >> 2) & 1);
        vec4 h = hash4(g_ + seed);
        vec3 c = g_ + 0.25 + 0.5 * h.xyz;
        if (h.w > density) continue;
        float r = mix(rad.x, rad.y, fract(h.w * 17.0 / density));
        float e = min(blur + aa / r, 0.7 / r - 1.0); // stay inside the 2x2x2 search
        float u = length(p - c) / r;
        if (u >= 1.0 + e) continue;
        float a = (1.0 - smoothstep(1.0 - e, 1.0 + e, u)) * (0.7 + 0.3 * smoothstep(0.3, 0.95, u));
        float k = fract(h.x * 5.0 + h.y * 3.0);
        vec3 tone = k < 0.4 ? u_glow_a : k < 0.8 ? u_glow_b : u_light;
        col = mix(col, tone, a * alpha);
    }
    return col;
}

// Four-point sparkle stars with a round core.
vec3 stars(vec3 col, vec3 p, float density, vec2 rad, float aa, float alpha, float seed) {
    vec3 cell_ = floor(p);
    vec3 base_ = cell_ - 1.0 + step(0.5, p - cell_);
    for (int i_ = 0; i_ < 8; i_++) {
        vec3 g_ = base_ + vec3(i_ & 1, (i_ >> 1) & 1, (i_ >> 2) & 1);
        vec4 h = hash4(g_ + seed);
        vec3 c = g_ + 0.25 + 0.5 * h.xyz;
        if (h.w > density) continue;
        float r = mix(rad.x, rad.y, fract(h.w * 17.0 / density));
        vec3 n = normalize(c);
        c = n * length(p); // on the sphere, so the flat star is not sliced at an angle
        vec3 t1 = normalize(cross(n, abs(n.y) < 0.9 ? vec3(0, 1, 0) : vec3(1, 0, 0)));
        vec3 t2 = cross(n, t1);
        vec2 q = vec2(dot(p - c, t1), dot(p - c, t2)) / r;
        float w = aa / r;
        float core = 1.0 - smoothstep(0.22 - w, 0.22 + w, length(q));
        float arms = max(1.0 - smoothstep(0.0, 0.07 + w, abs(q.x) * (0.6 + abs(q.y) * 3.0)),
                         1.0 - smoothstep(0.0, 0.07 + w, abs(q.y) * (0.6 + abs(q.x) * 3.0)));
        arms *= 1.0 - smoothstep(0.4, 1.0, length(q));
        float k = fract(h.x * 5.0 + h.y * 3.0);
        vec3 tone = k < 0.6 ? u_light : k < 0.8 ? u_glow_a : u_glow_b;
        col = mix(col, tone, max(core, arms) * alpha);
    }
    return col;
}

void main() {
    mat3 R = mat3(u_view);
    mat3 Rt = transpose(R);
    cam_pos = -(Rt * u_view[3].xyz);
    ray_dir = normalize(Rt * normalize(vec3(v_ndc * u_tan, -1.0)));
    vec3 col = u_bg;
    float vig = smoothstep(0.4, 1.6, length(v_ndc));
    if (u_mode == 0) {
        col = mix(col, u_ink, 0.25 * vig);
        // Far: big, heavily defocused cells.
        float s1 = 2.6;
        col = cells(col, shellDir(11.0) * s1, 0.55, vec2(0.26, 0.48), 0.10, dof(11.0, s1, 1.0), 0.55, 3.0);
        // Middle: smaller cells, less blurred.
        float s2 = 6.0;
        col = cells(col, shellDir(7.0) * s2, 0.30, vec2(0.16, 0.30), 0.03, dof(7.0, s2, 1.0), 0.45, 11.0);
        // Near: drifting vesicles, soft.
        float s3 = 16.0;
        col = dots(col, shellDir(4.8) * s3, 0.22, vec2(0.05, 0.11), dof(4.8, s3, 1.0), 0.40, 29.0, u_deep, u_light);
    } else {
        // Nebula haze: slow noise, tinted toward the two glow colours.
        vec3 hd = shellDir(14.0);
        float n1 = noise(hd * 2.2) * 0.6 + noise(hd * 4.7 + 7.0) * 0.4;
        float n2 = noise(hd * 1.8 + 31.0);
        float haze = smoothstep(0.45, 0.85, n1);
        col = mix(col, mix(u_glow_a, u_glow_b, n2), haze * 0.22);
        col = mix(col, u_ink, 0.35 * vig);
        // Far: big defocused bokeh.
        float s1 = 3.0;
        col = bokeh(col, shellDir(11.0) * s1, 0.45, vec2(0.18, 0.40), 0.08, dof(11.0, s1, 1.0), 0.20, 5.0);
        // Middle: small soft glows.
        float s2 = 9.0;
        col = bokeh(col, shellDir(7.0) * s2, 0.30, vec2(0.07, 0.15), 0.08, dof(7.0, s2, 1.0), 0.28, 13.0);
        // Near: a few sparkle stars, and a dusting of tiny ones farther off.
        float s3 = 7.0;
        col = stars(col, shellDir(5.0) * s3, 0.07, vec2(0.16, 0.30), dof(5.0, s3, 0.25), 0.45, 23.0);
        float s4 = 30.0;
        col = dots(col, shellDir(9.0) * s4, 0.25, vec2(0.04, 0.08), dof(9.0, s4, 0.5), 0.35, 37.0, u_light, u_glow_b);
    }
    o_color = vec4(col, 1.0);
}
