// Shared by every scene shader: the per-frame uniform block (mirrored by
// `Renderer.FrameUniforms`) and the per-draw push constants (`Renderer.Push`).
//
// Shading modes (u_cel): 1 = cel/toon (flat bands, outlines), 2 = flat,
// inspired by Kurzgesagt (one solid colour per object, highlight dots on
// atoms, depth shown by fading toward the background, flat offset drop
// shadows, no outlines). Outlines have a constant screen width:
// `u_outline_k` is the outline width in world units per unit of view depth.
//
// The camera's projection is OpenGL-style (clip z in [-w, w]); vertex shaders
// remap it with `toVulkanDepth`, and fragment shaders that write depth use
// the matching `z / w * 0.5 + 0.5`. The viewport is flipped (negative height)
// so NDC y points up, as in OpenGL.

layout(set = 0, binding = 0, std140) uniform Frame {
    mat4 u_view;
    mat4 u_proj;
    vec3 u_outline_color;
    float u_fog_amount;
    vec3 u_select_color;
    float u_select_k;
    vec3 u_fog_color;
    int u_cel;
    vec3 u_shadow_color;
    float u_pad0;
    vec2 u_fog_range;
    vec2 u_pad1;
    // Background pattern (background.frag).
    vec3 u_bg;
    int u_mode;
    vec3 u_ink;          // main tone
    float u_radius;      // scene radius at fit time
    vec3 u_deep;         // stronger tone (rims, nuclei)
    float u_px;          // view-plane units per target pixel
    vec3 u_light;        // tone on the other side of the background
    float u_coc_px;      // lens blur scale, target pixels
    vec3 u_glow_a;
    float u_pad2;
    vec3 u_glow_b;
    float u_pad3;
    vec3 u_anchor;       // world anchor of the pattern shells
    float u_pad4;
    vec2 u_tan;          // tan(fovy/2) * aspect, tan(fovy/2)
    vec2 u_pad5;
};

layout(push_constant) uniform Draw {
    vec2 u_shadow_offset;
    float u_shadow_pass;
    float u_outline_k;
    int u_outline_pass;
};

vec4 toVulkanDepth(vec4 clip) {
    clip.z = 0.5 * (clip.z + clip.w);
    return clip;
}
