// Boo preset: curved CRT glass, scanlines, vignette and slight color fringe.
const float CURVE = 0.04;

vec2 curve(vec2 uv) {
    uv = uv * 2.0 - 1.0;
    vec2 offset = abs(uv.yx) * CURVE;
    uv = uv + uv * offset * offset * 4.0;
    return uv * 0.5 + 0.5;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = curve(fragCoord / iResolution.xy);
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        fragColor = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }
    float fringe = 0.6 / iResolution.x;
    vec3 color;
    color.r = texture(iChannel0, uv + vec2(fringe, 0.0)).r;
    color.g = texture(iChannel0, uv).g;
    color.b = texture(iChannel0, uv - vec2(fringe, 0.0)).b;
    color *= mix(0.85, 1.0, 0.5 + 0.5 * sin(fragCoord.y * 3.14159));
    vec2 v = uv * (1.0 - uv.yx);
    color *= clamp(pow(v.x * v.y * 18.0, 0.18), 0.0, 1.0);
    fragColor = vec4(color, 1.0);
}
