#version 450
// Upsamples the cached backdrop (background.frag, rendered at reduced
// resolution into a half-float image) to the scene target.

layout(set = 0, binding = 1) uniform sampler2D u_tex;

layout(location = 0) in vec2 v_ndc;
layout(location = 0) out vec4 o_color;

void main() {
    vec3 col = texture(u_tex, v_ndc * 0.5 + 0.5).rgb;
    // Dither (about +/-0.5/255) so soft gradients do not band; interleaved
    // gradient noise (Jimenez 2014) is cheaper than a sin hash.
    float dn = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))));
    o_color = vec4(col + (dn - 0.5) / 255.0, 1.0);
}
