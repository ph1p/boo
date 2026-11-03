// Boo preset: curved CRT glass, scanlines, vignette and slight color fringe.
// Scanlines follow the curved glass and are spaced in device pixels so they
// read on Retina. The glass edge is anti-aliased instead of a hard black cut.
const float CURVE = 0.035;
const float LINE_PX = 3.0;
const float SCAN_DEPTH = 0.2;
const float FRINGE_PX = 0.8;

vec2 curve(vec2 uv) {
    uv = uv * 2.0 - 1.0;
    vec2 offset = abs(uv.yx) * CURVE;
    uv = uv + uv * offset * offset * 4.0;
    return uv * 0.5 + 0.5;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = curve(fragCoord / iResolution.xy);

    // Soft mask at the edge of the glass, about two device pixels wide.
    vec2 edge = 2.0 / iResolution.xy;
    vec2 inside = smoothstep(vec2(0.0), edge, uv) * smoothstep(vec2(0.0), edge, 1.0 - uv);
    float mask = inside.x * inside.y;

    vec2 c = clamp(uv, 0.0, 1.0);
    float fringe = FRINGE_PX / iResolution.x;
    vec3 color;
    color.r = texture(iChannel0, c + vec2(fringe, 0.0)).r;
    color.g = texture(iChannel0, c).g;
    color.b = texture(iChannel0, c - vec2(fringe, 0.0)).b;

    float phase = fract(uv.y * iResolution.y / LINE_PX);
    float gap = smoothstep(0.0, 1.0, 1.0 - abs(phase * 2.0 - 1.0));
    color *= (1.0 - SCAN_DEPTH * gap) * (1.0 + SCAN_DEPTH * 0.4);

    vec2 v = c * (1.0 - c.yx);
    color *= clamp(pow(v.x * v.y * 20.0, 0.15), 0.0, 1.0);

    fragColor = vec4(color * mask, 1.0);
}
