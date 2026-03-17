import simd

/// Per-instance vertex data for a terminal cell quad
struct CellInstance {
    var position: SIMD2<Float>     // top-left position in pixels
    var size: SIMD2<Float>         // cell width, cell height
    var uvOrigin: SIMD2<Float>     // glyph UV origin in atlas
    var uvSize: SIMD2<Float>       // glyph UV size in atlas
    var fgColor: SIMD4<Float>      // foreground RGBA
    var bgColor: SIMD4<Float>      // background RGBA
    var flags: UInt32              // bit 0: has glyph, bit 1: is cursor, bit 2: underline
    var _pad: SIMD3<Float> = .zero
}

/// Uniform data passed to shaders
struct Uniforms {
    var viewportSize: SIMD2<Float>
}
