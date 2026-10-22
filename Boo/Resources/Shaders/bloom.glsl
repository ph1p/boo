// Boo preset: soft glow around bright text.
const float RADIUS = 2.5;
const float STRENGTH = 0.35;

float luma(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec2 px = RADIUS / iResolution.xy;
    vec4 base = texture(iChannel0, uv);
    vec3 glow = vec3(0.0);
    float total = 0.0;
    for (int x = -2; x <= 2; x++) {
        for (int y = -2; y <= 2; y++) {
            vec2 offset = vec2(float(x), float(y));
            float w = exp(-dot(offset, offset) / 4.0);
            vec3 s = texture(iChannel0, uv + offset * px).rgb;
            glow += s * smoothstep(0.45, 0.9, luma(s)) * w;
            total += w;
        }
    }
    fragColor = vec4(base.rgb + glow / total * STRENGTH, base.a);
}
