// Boo preset: subtle horizontal scanlines.
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec4 color = texture(iChannel0, uv);
    float line = 0.5 + 0.5 * sin(fragCoord.y * 3.14159);
    color.rgb *= mix(0.82, 1.0, line);
    fragColor = color;
}
