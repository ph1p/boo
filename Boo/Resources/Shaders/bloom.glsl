// Boo preset: soft glow around bright text.
// Two sample rings for a wider, smoother halo. The glow fades out on light
// backgrounds, where blooming the page would only blur dark text.
const float RADIUS = 3.0;
const float STRENGTH = 0.45;

float luma(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec2 px = RADIUS / iResolution.xy;
    vec4 base = texture(iChannel0, uv);
    vec3 glow = vec3(0.0);
    float total = 0.0;
    float avg = 0.0;
    for (int ring = 1; ring <= 2; ring++) {
        float r = float(ring);
        float w = ring == 1 ? 1.0 : 0.5;
        for (int i = 0; i < 8; i++) {
            float a = float(i) * 0.785398 + r * 0.39;
            vec3 s = texture(iChannel0, uv + vec2(cos(a), sin(a)) * px * r).rgb;
            float l = luma(s);
            glow += s * smoothstep(0.4, 0.85, l) * w;
            avg += l * w;
            total += w;
        }
    }
    avg /= total;
    float darkBg = 1.0 - smoothstep(0.35, 0.6, avg);
    fragColor = vec4(base.rgb + glow / total * STRENGTH * darkBg, base.a);
}
