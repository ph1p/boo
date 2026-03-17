import Metal
import CoreText
import CoreGraphics
import Foundation

/// Rasterizes monospace font glyphs into a Metal texture atlas.
final class GlyphAtlas {
    let texture: MTLTexture
    let cellWidth: CGFloat
    let cellHeight: CGFloat

    private let atlasWidth: Int
    private let atlasHeight: Int
    private let glyphMap: [Character: GlyphEntry]

    struct GlyphEntry {
        var uvOrigin: SIMD2<Float>
        var uvSize: SIMD2<Float>
    }

    init(device: MTLDevice, font: CTFont, fontSize: CGFloat, scale: CGFloat = 2.0) {
        let ctFont = font

        // Measure cell dimensions in points
        let refGlyph: [CGGlyph] = {
            var g: CGGlyph = 0
            var u: UniChar = 0x4D // 'M'
            CTFontGetGlyphsForCharacters(ctFont, &u, &g, 1)
            return [g]
        }()

        var advances = [CGSize](repeating: .zero, count: 1)
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, refGlyph, &advances, 1)
        let cw = ceil(advances[0].width)
        let ch = ceil(CTFontGetAscent(ctFont) + CTFontGetDescent(ctFont) + CTFontGetLeading(ctFont))
        self.cellWidth = cw   // in points
        self.cellHeight = ch  // in points

        // Atlas in pixels (scaled for Retina)
        let gridCols = 16
        let gridRows = 8
        let pixelCW = Int(ceil(cw * scale))
        let pixelCH = Int(ceil(ch * scale))
        let atlasW = pixelCW * gridCols
        let atlasH = pixelCH * gridRows
        self.atlasWidth = atlasW
        self.atlasHeight = atlasH

        // Rasterize glyphs into a bitmap at pixel resolution
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil,
            width: atlasW,
            height: atlasH,
            bitsPerComponent: 8,
            bytesPerRow: atlasW,
            space: colorSpace,
            bitmapInfo: 0
        ) else {
            fatalError("Failed to create glyph atlas context")
        }

        // Scale the context so CoreText draws at Retina resolution
        context.scaleBy(x: scale, y: scale)

        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setShouldSmoothFonts(true)

        // Clear to black
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(atlasW) / scale, height: CGFloat(atlasH) / scale))

        var map = [Character: GlyphEntry]()
        let ascent = CTFontGetAscent(ctFont)

        // Rasterize printable ASCII range (32-126)
        for i in 0..<(gridCols * gridRows) {
            let codePoint = 32 + i
            guard codePoint <= 126 else { break }

            let col = i % gridCols
            let row = i / gridCols

            // Position in point-space (context is scaled)
            let x = CGFloat(col) * cw
            let totalPointH = CGFloat(atlasH) / scale
            let y = totalPointH - CGFloat(row + 1) * ch

            var unichars: [UniChar] = [UniChar(codePoint)]
            var glyphs: [CGGlyph] = [0]
            CTFontGetGlyphsForCharacters(ctFont, &unichars, &glyphs, 1)

            if glyphs[0] != 0 {
                let pos = CGPoint(x: x, y: y + (ch - ascent) * 0.5)
                CTFontDrawGlyphs(ctFont, glyphs, [pos], 1, context)
            }

            // UV coordinates are in pixel-space (atlas texture coords)
            let char = Character(UnicodeScalar(codePoint)!)
            map[char] = GlyphEntry(
                uvOrigin: SIMD2<Float>(
                    Float(col * pixelCW) / Float(atlasW),
                    Float(row * pixelCH) / Float(atlasH)
                ),
                uvSize: SIMD2<Float>(
                    Float(pixelCW) / Float(atlasW),
                    Float(pixelCH) / Float(atlasH)
                )
            )
        }

        self.glyphMap = map

        // Create Metal texture
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: atlasW,
            height: atlasH,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]

        guard let tex = device.makeTexture(descriptor: descriptor) else {
            fatalError("Failed to create glyph atlas texture")
        }

        // Upload rasterized glyphs
        guard let data = context.data else { fatalError("No context data") }
        tex.replace(
            region: MTLRegionMake2D(0, 0, atlasW, atlasH),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: atlasW
        )

        self.texture = tex
    }

    func entry(for char: Character) -> GlyphEntry? {
        glyphMap[char]
    }
}
