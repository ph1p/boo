// Boo preset: subtle horizontal scanlines.
// One line every LINE_PX device pixels, so the pattern stays visible on Retina
// instead of collapsing into a 1px moiré. Brightness is lifted slightly to make
// up for the darkened gaps.
const float LINE_PX = 3.0;
const float DEPTH = 0.16;

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec4 color = texture(iChannel0, uv);
    float phase = fract(fragCoord.y / LINE_PX);
    float gap = smoothstep(0.0, 1.0, 1.0 - abs(phase * 2.0 - 1.0));
    color.rgb *= (1.0 - DEPTH * gap) * (1.0 + DEPTH * 0.35);
    fragColor = color;
}
