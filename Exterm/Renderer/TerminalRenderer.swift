import Metal
import MetalKit
import CoreText

/// Renders terminal content using Metal instanced drawing.
final class TerminalRenderer {
    private let device: MTLDevice
    private let pipelineState: MTLRenderPipelineState
    private let glyphAtlas: GlyphAtlas
    private var instanceBuffer: MTLBuffer?
    private var uniformBuffer: MTLBuffer?

    init(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        self.device = device

        // Create glyph atlas
        let fontSize: CGFloat = 14.0
        let font = CTFontCreateWithName("Menlo" as CFString, fontSize, nil)
        self.glyphAtlas = GlyphAtlas(device: device, font: font, fontSize: fontSize)

        // Compile shaders from source
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: metalShaderSource, options: nil)
        } catch {
            fatalError("Failed to compile Metal shaders: \(error)")
        }

        let vertexFunction = library.makeFunction(name: "cellVertex")
        let fragmentFunction = library.makeFunction(name: "cellFragment")

        // Pipeline
        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction = vertexFunction
        pipelineDesc.fragmentFunction = fragmentFunction
        pipelineDesc.colorAttachments[0].pixelFormat = pixelFormat

        // Enable alpha blending
        pipelineDesc.colorAttachments[0].isBlendingEnabled = true
        pipelineDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha

        do {
            self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDesc)
        } catch {
            fatalError("Failed to create pipeline state: \(error)")
        }

        // Allocate uniform buffer
        self.uniformBuffer = device.makeBuffer(length: MemoryLayout<Uniforms>.stride, options: .storageModeShared)
    }

    var cellWidth: CGFloat { glyphAtlas.cellWidth }
    var cellHeight: CGFloat { glyphAtlas.cellHeight }

    func draw(
        terminal: VT100Terminal,
        cursorVisible: Bool,
        in view: MTKView,
        commandBuffer: MTLCommandBuffer,
        renderPassDescriptor: MTLRenderPassDescriptor
    ) {
        let cols = terminal.cols
        let rows = terminal.rows
        let instanceCount = cols * rows

        // Build instance data
        let bufferSize = instanceCount * MemoryLayout<CellInstance>.stride
        if instanceBuffer == nil || instanceBuffer!.length < bufferSize {
            instanceBuffer = device.makeBuffer(length: bufferSize, options: .storageModeShared)
        }

        guard let instanceBuffer = instanceBuffer else { return }
        let instances = instanceBuffer.contents().bindMemory(to: CellInstance.self, capacity: instanceCount)

        // Scale cell sizes to pixel coordinates (drawable is in pixels, not points)
        let scale = Float(view.window?.backingScaleFactor ?? 2.0)
        let cw = Float(glyphAtlas.cellWidth) * scale
        let ch = Float(glyphAtlas.cellHeight) * scale

        for row in 0..<rows {
            for col in 0..<cols {
                let idx = row * cols + col
                let cell = terminal.cell(at: col, row: row)
                let style = cell.style

                var fg = style.fg
                var bg = style.bg
                if style.inverse { swap(&fg, &bg) }
                if style.bold && fg == .defaultFG { fg = .white }

                let isCursor = col == terminal.cursorX && row == terminal.cursorY && cursorVisible
                let hasGlyph = cell.character != " "
                let isUnderline = style.underline

                var flags: UInt32 = 0
                if hasGlyph { flags |= 1 }
                if isCursor { flags |= 2 }
                if isUnderline { flags |= 4 }

                let entry = glyphAtlas.entry(for: cell.character)

                instances[idx] = CellInstance(
                    position: SIMD2<Float>(Float(col) * cw, Float(row) * ch),
                    size: SIMD2<Float>(cw, ch),
                    uvOrigin: entry?.uvOrigin ?? .zero,
                    uvSize: entry?.uvSize ?? .zero,
                    fgColor: colorToFloat4(fg),
                    bgColor: colorToFloat4(bg),
                    flags: flags
                )
            }
        }

        // Update uniforms
        let viewportSize = SIMD2<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height))
        uniformBuffer?.contents().storeBytes(of: Uniforms(viewportSize: viewportSize), as: Uniforms.self)

        // Encode draw call
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        encoder.setFragmentTexture(glyphAtlas.texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: instanceCount)
        encoder.endEncoding()
    }

    private func colorToFloat4(_ c: TerminalColor) -> SIMD4<Float> {
        SIMD4<Float>(Float(c.r) / 255, Float(c.g) / 255, Float(c.b) / 255, 1)
    }
}
