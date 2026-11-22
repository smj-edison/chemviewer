#version 450
// One triangle covering the target; v_ndc is the NDC position (y up in the
// scene's flipped viewport, y down in the backdrop cache: see Renderer).

layout(location = 0) out vec2 v_ndc;

void main() {
    vec2 p = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2) * 2.0 - 1.0;
    v_ndc = p;
    gl_Position = vec4(p, 0.0, 1.0);
}
