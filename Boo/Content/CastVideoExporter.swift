import AVFoundation
import CGhosttyVT
import Cocoa
import CoreText

/// Renders an asciicast recording to an H.264 MP4, offline and faster than
/// real time: a headless libghostty-vt terminal replays the cast on the
/// (idle-capped) playback timeline and each frame is drawn with CoreText.
enum CastVideoExporter {
    static let fps: Int32 = 30
    /// The last frame stays up this long so the video doesn't cut off.
    static let tail: TimeInterval = 1
    /// Synchronized-output holds longer than this are abandoned, as on screen.
    static let holdTimeout: TimeInterval = 1
    static let maxSize = CGSize(width: 3840, height: 2160)

    /// Look of the rendered terminal, captured on the main actor.
    struct Style: Sendable {
        var foreground: TerminalColor
        var background: TerminalColor
        var cursor: TerminalColor
        var ansi: [TerminalColor]
        var fontName: String
        var fontSize: CGFloat
        var cursorStyle: CursorStyle

        @MainActor static var current: Style {
            let s = AppSettings.shared
            let t = s.theme
            return Style(
                foreground: t.foreground, background: t.background, cursor: t.cursor, ansi: t.ansiColors,
                fontName: s.fontName, fontSize: CGFloat(s.fontSize), cursorStyle: s.cursorStyle)
        }

        /// libghostty-vt cursor style for `cursorStyle`.
        var vtCursorStyle: UInt8 {
            switch cursorStyle {
            case .beam: return 0
            case .block: return 1
            case .underline: return 2
            case .blockOutline: return 3
            }
        }
    }

    enum ExportError: LocalizedError {
        case unreadable(String)
        case notACast
        case emptyRecording
        case terminal
        case writer(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let reason): return "The recording couldn't be read: \(reason)"
            case .notACast: return "The file isn't an asciicast v2 recording."
            case .emptyRecording: return "The recording has no output."
            case .terminal: return "The terminal emulator couldn't be created."
            case .writer(let reason): return "The video couldn't be written: \(reason)"
            }
        }
    }

    // MARK: - Geometry

    /// Pixel layout of the video: the largest grid in the recording, scaled
    /// down to fit `maxSize`, padded, with even dimensions for H.264.
    struct Geometry: Equatable {
        let scale: CGFloat
        let cell: CGSize
        let padding: CGFloat
        let size: CGSize

        /// `cell` is the cell size at scale 1.
        static func make(
            columns: Int, rows: Int, cell: CGSize, preferredScale: CGFloat = 2, padding: CGFloat = 12,
            maxSize: CGSize = CastVideoExporter.maxSize
        ) -> Geometry {
            let cols = CGFloat(max(1, columns))
            let rws = CGFloat(max(1, rows))
            let w1 = cols * cell.width + 2 * padding
            let h1 = rws * cell.height + 2 * padding
            let scale = max(0.25, min(preferredScale, maxSize.width / w1, maxSize.height / h1))
            // Rounding down keeps the result within maxSize.
            let c = CGSize(
                width: max(1, (cell.width * scale).rounded(.down)), height: max(1, (cell.height * scale).rounded(.down))
            )
            let pad = (padding * scale).rounded(.down)
            let w = even(cols * c.width + 2 * pad)
            let h = even(rws * c.height + 2 * pad)
            return Geometry(scale: scale, cell: c, padding: pad, size: CGSize(width: w, height: h))
        }

        private static func even(_ v: CGFloat) -> CGFloat {
            let i = Int(v.rounded(.up))
            return CGFloat(i - (i & 1))
        }
    }

    /// Largest grid the recording uses (header size and every resize).
    static func maxGrid(_ pb: CastPlayback) -> (columns: Int, rows: Int) {
        var cols = pb.width
        var rows = pb.height
        for e in pb.events {
            if case .resize(let c, let r) = e.event {
                cols = max(cols, c)
                rows = max(rows, r)
            }
        }
        return (cols, rows)
    }

    /// Frames for `duration` seconds of playback plus the tail.
    static func frameCount(duration: TimeInterval) -> Int {
        Int(((max(0, duration) + tail) * Double(fps)).rounded(.up)) + 1
    }

    static func defaultFileName(for castPath: String) -> String {
        ((castPath as NSString).lastPathComponent as NSString).deletingPathExtension + ".mp4"
    }

    // MARK: - Export

    /// Writes `cast` to `output` (replacing it). Checks for task cancellation
    /// between frames; `progress` gets 0...1.
    static func export(
        cast: URL, to output: URL, style: Style, idleLimit: TimeInterval,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let text: String
        do {
            text = try String(contentsOf: cast, encoding: .utf8)
        } catch {
            throw ExportError.unreadable(error.localizedDescription)
        }
        guard let pb = try? CastPlayback(text: text, fallbackIdleLimit: idleLimit) else {
            throw ExportError.notACast
        }
        guard !pb.events.isEmpty else { throw ExportError.emptyRecording }

        let painter = FramePainter(style: style)
        let grid = maxGrid(pb)
        let geometry = Geometry.make(columns: grid.columns, rows: grid.rows, cell: painter.baseCell)
        painter.prepare(geometry)

        guard let vt = boo_vt_new(UInt16(clamping: pb.width), UInt16(clamping: pb.height)) else {
            throw ExportError.terminal
        }
        defer { boo_vt_free(vt) }
        var ansi = (0..<16).map { i in i < style.ansi.count ? pack(style.ansi[i]) : 0 }
        boo_vt_set_colors(vt, pack(style.foreground), pack(style.background), pack(style.cursor), &ansi)
        boo_vt_set_cursor_style(vt, style.vtCursorStyle)

        try? FileManager.default.removeItem(at: output)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        } catch {
            throw ExportError.writer(error.localizedDescription)
        }
        let width = Int(geometry.size.width)
        let height = Int(geometry.size.height)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: max(2_000_000, width * height * 3),
                    AVVideoExpectedSourceFrameRateKey: Int(fps),
                    AVVideoMaxKeyFrameIntervalDurationKey: 2,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ] as [String: Any]
            ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ])
        guard writer.canAdd(input) else { throw ExportError.writer("unsupported video settings") }
        writer.add(input)
        guard writer.startWriting() else {
            throw ExportError.writer(writer.error?.localizedDescription ?? "unknown error")
        }
        writer.startSession(atSourceTime: .zero)

        do {
            try render(pb, vt: vt, painter: painter, writer: writer, input: input, adaptor: adaptor, progress: progress)
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            try? FileManager.default.removeItem(at: output)
            throw ExportError.writer(writer.error?.localizedDescription ?? "unknown error")
        }
        progress(1)
    }

    private static func render(
        _ pb: CastPlayback, vt: OpaquePointer, painter: FramePainter, writer: AVAssetWriter,
        input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor,
        progress: @Sendable (Double) -> Void
    ) throws {
        let total = frameCount(duration: pb.duration)
        var cursor = 0
        var holdStart: TimeInterval?
        var last: CVPixelBuffer?
        var reported = -1

        for frame in 0..<total {
            try Task.checkCancellation()
            let t = Double(frame) / Double(fps)

            // Feed everything due by this frame; resizes apply in order.
            let end = pb.dueIndex(at: t, from: cursor)
            var batch: [UInt8] = []
            while cursor < end {
                switch pb.events[cursor].event {
                case .output(let s):
                    batch.append(contentsOf: s.utf8)
                case .resize(let c, let r):
                    write(vt, &batch)
                    boo_vt_resize(vt, UInt16(clamping: c), UInt16(clamping: r))
                }
                cursor += 1
            }
            write(vt, &batch)

            if boo_vt_held(vt) {
                if let start = holdStart, t - start >= holdTimeout {
                    boo_vt_end_hold(vt)
                    holdStart = nil
                } else if holdStart == nil {
                    holdStart = t
                }
            } else {
                holdStart = nil
            }

            var buffer = last
            if boo_vt_update(vt) || buffer == nil {
                guard let pool = adaptor.pixelBufferPool else {
                    throw ExportError.writer(writer.error?.localizedDescription ?? "no pixel buffer pool")
                }
                var fresh: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &fresh)
                guard let fresh else { throw ExportError.writer("out of memory") }
                var info = BooVTFrame()
                var text: UnsafePointer<CChar>?
                let cells = boo_vt_capture(vt, &info, &text)
                painter.draw(into: fresh, frame: info, cells: cells, text: text)
                buffer = fresh
                last = fresh
            }

            while !input.isReadyForMoreMediaData {
                if writer.status == .failed {
                    throw ExportError.writer(writer.error?.localizedDescription ?? "unknown error")
                }
                try Task.checkCancellation()
                Thread.sleep(forTimeInterval: 0.002)
            }
            if let buffer,
                !adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
            {
                throw ExportError.writer(writer.error?.localizedDescription ?? "frame rejected")
            }

            let pct = frame * 100 / max(1, total)
            if pct != reported {
                reported = pct
                progress(Double(frame) / Double(total))
            }
        }
    }

    private static func write(_ vt: OpaquePointer, _ batch: inout [UInt8]) {
        guard !batch.isEmpty else { return }
        batch.withUnsafeBufferPointer { boo_vt_write(vt, $0.baseAddress, $0.count) }
        batch.removeAll(keepingCapacity: true)
    }

    static func pack(_ c: TerminalColor) -> UInt32 {
        UInt32(c.r) << 16 | UInt32(c.g) << 8 | UInt32(c.b)
    }
}

// MARK: - Drawing

/// Draws captured grids into BGRA pixel buffers. Not thread-safe; one per export.
private final class FramePainter {
    private let style: CastVideoExporter.Style
    private let baseFont: CTFont
    private var geometry = CastVideoExporter.Geometry(scale: 1, cell: .zero, padding: 0, size: .zero)
    private var fonts: [CTFont] = []  // regular, bold, italic, bold italic
    private var ascent: CGFloat = 0
    private var descent: CGFloat = 0
    private var underlinePosition: CGFloat = 0
    private var lineWidth: CGFloat = 1
    private var lines: [LineKey: CTLine] = [:]
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private struct LineKey: Hashable {
        let text: String
        let font: Int
    }

    init(style: CastVideoExporter.Style) {
        self.style = style
        let size = max(6, style.fontSize)
        let font = CTFontCreateWithName(style.fontName as CFString, size, nil)
        // An unknown name falls back to Helvetica; keep the grid monospaced.
        if CTFontGetSymbolicTraits(font).contains(.traitMonoSpace) {
            baseFont = font
        } else {
            baseFont = CTFontCreateUIFontForLanguage(.userFixedPitch, size, nil) ?? font
        }
    }

    /// Cell size at scale 1.
    var baseCell: CGSize { Self.cellSize(baseFont) }

    private static func cellSize(_ font: CTFont) -> CGSize {
        var glyph = CGGlyph()
        var ch: UniChar = 0x4D  // "M"
        CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        let height = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        return CGSize(width: max(1, advance.width.rounded()), height: max(1, height.rounded(.up)))
    }

    func prepare(_ geometry: CastVideoExporter.Geometry) {
        self.geometry = geometry
        let size = CTFontGetSize(baseFont) * geometry.scale
        let regular = CTFontCreateCopyWithAttributes(baseFont, size, nil, nil)
        func variant(_ traits: CTFontSymbolicTraits) -> CTFont {
            CTFontCreateCopyWithSymbolicTraits(regular, size, nil, traits, traits) ?? regular
        }
        fonts = [regular, variant(.traitBold), variant(.traitItalic), variant([.traitBold, .traitItalic])]
        ascent = CTFontGetAscent(regular)
        descent = CTFontGetDescent(regular)
        underlinePosition = CTFontGetUnderlinePosition(regular)
        lineWidth = max(1, CTFontGetUnderlineThickness(regular).rounded())
        lines.removeAll()
    }

    func draw(
        into buffer: CVPixelBuffer, frame: BooVTFrame, cells: UnsafePointer<BooVTCell>?, text: UnsafePointer<CChar>?
    ) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard
            let ctx = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: CVPixelBufferGetWidth(buffer),
                height: CVPixelBufferGetHeight(buffer), bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }

        ctx.setFillColor(color(frame.bg))
        ctx.fill(CGRect(origin: .zero, size: geometry.size))
        guard let cells else { return }
        let cols = Int(frame.cols)
        let rows = Int(frame.rows)
        let cw = geometry.cell.width
        let ch = geometry.cell.height

        // Backgrounds first, so wide glyphs aren't clipped by the next cell.
        for y in 0..<rows {
            var x = 0
            while x < cols {
                let cell = cells[y * cols + x]
                guard cell.has_bg != 0 else {
                    x += 1
                    continue
                }
                var run = 1
                while x + run < cols, cells[y * cols + x + run].has_bg != 0, cells[y * cols + x + run].bg == cell.bg {
                    run += 1
                }
                ctx.setFillColor(color(cell.bg))
                ctx.fill(CGRect(x: cellX(x), y: cellY(y), width: cw * CGFloat(run), height: ch))
                x += run
            }
        }

        let cursorCell: (x: Int, y: Int)? =
            frame.cursor_visible ? (Int(frame.cursor_x) - (frame.cursor_wide ? 1 : 0), Int(frame.cursor_y)) : nil
        let cursorColor = color(frame.cursor_has_color ? frame.cursor_color : frame.fg)
        let blockCursor = cursorCell != nil && frame.cursor_style == 1
        if let c = cursorCell, blockCursor, c.y < rows, c.x >= 0, c.x < cols {
            let wide = cells[c.y * cols + c.x].wide == UInt8(BOO_VT_WIDE)
            ctx.setFillColor(cursorColor)
            ctx.fill(CGRect(x: cellX(c.x), y: cellY(c.y), width: cw * (wide ? 2 : 1), height: ch))
        }

        ctx.textMatrix = .identity
        for y in 0..<rows {
            for x in 0..<cols {
                let cell = cells[y * cols + x]
                let underCursor = blockCursor && cursorCell.map { $0.x == x && $0.y == y } == true
                let fg = underCursor ? color(frame.bg) : color(cell.fg, faint: cell.flags & UInt8(BOO_VT_FAINT) != 0)
                if cell.text_len > 0, let text {
                    drawText(ctx, cell: cell, text: text, x: x, y: y, color: fg)
                }
                drawDecorations(ctx, cell: cell, x: x, y: y, color: fg)
            }
        }

        if let c = cursorCell, !blockCursor, c.y < rows, c.x >= 0, c.x < cols {
            let wide = cells[c.y * cols + c.x].wide == UInt8(BOO_VT_WIDE)
            let rect = CGRect(x: cellX(c.x), y: cellY(c.y), width: cw * (wide ? 2 : 1), height: ch)
            let thick = max(1, (2 * geometry.scale).rounded())
            ctx.setFillColor(cursorColor)
            switch frame.cursor_style {
            case 0: ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: thick, height: rect.height))
            case 2: ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: thick))
            default:
                ctx.setStrokeColor(cursorColor)
                ctx.setLineWidth(thick)
                ctx.stroke(rect.insetBy(dx: thick / 2, dy: thick / 2))
            }
        }
    }

    private func drawText(
        _ ctx: CGContext, cell: BooVTCell, text: UnsafePointer<CChar>, x: Int, y: Int, color: CGColor
    ) {
        let bytes = UnsafeRawPointer(text + Int(cell.text_offset)).assumingMemoryBound(to: UInt8.self)
        let string = String(decoding: UnsafeBufferPointer(start: bytes, count: Int(cell.text_len)), as: UTF8.self)
        if string == " " { return }
        let bold = cell.flags & UInt8(BOO_VT_BOLD) != 0
        let italic = cell.flags & UInt8(BOO_VT_ITALIC) != 0
        let key = LineKey(text: string, font: (bold ? 1 : 0) | (italic ? 2 : 0))
        let line: CTLine
        if let cached = lines[key] {
            line = cached
        } else {
            let attrs: [CFString: Any] = [
                kCTFontAttributeName: fonts[key.font],
                kCTForegroundColorFromContextAttributeName: true
            ]
            line = CTLineCreateWithAttributedString(
                CFAttributedStringCreate(nil, string as CFString, attrs as CFDictionary))
            if lines.count > 4096 { lines.removeAll() }
            lines[key] = line
        }
        ctx.setFillColor(color)
        ctx.textPosition = CGPoint(x: cellX(x), y: baseline(y))
        CTLineDraw(line, ctx)
    }

    private func drawDecorations(_ ctx: CGContext, cell: BooVTCell, x: Int, y: Int, color: CGColor) {
        let hasLine = cell.underline != 0 || cell.flags & UInt8(BOO_VT_STRIKE | BOO_VT_OVERLINE) != 0
        guard hasLine else { return }
        let left = cellX(x)
        let width = geometry.cell.width
        ctx.setFillColor(color)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(lineWidth)
        let underY = (baseline(y) + underlinePosition - lineWidth).rounded()
        switch cell.underline {
        case 0: break
        case 2:
            ctx.fill(CGRect(x: left, y: underY, width: width, height: lineWidth))
            ctx.fill(CGRect(x: left, y: underY - 2 * lineWidth, width: width, height: lineWidth))
        case 3:
            let amp = max(1, lineWidth)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: left, y: underY))
            path.addCurve(
                to: CGPoint(x: left + width, y: underY), control1: CGPoint(x: left + width / 3, y: underY + 2 * amp),
                control2: CGPoint(x: left + 2 * width / 3, y: underY - 2 * amp))
            ctx.addPath(path)
            ctx.strokePath()
        case 4, 5:
            let dash = cell.underline == 4 ? lineWidth : width / 4
            var dx: CGFloat = 0
            while dx < width {
                ctx.fill(CGRect(x: left + dx, y: underY, width: min(dash, width - dx), height: lineWidth))
                dx += dash * 2
            }
        default:
            ctx.fill(CGRect(x: left, y: underY, width: width, height: lineWidth))
        }
        if cell.flags & UInt8(BOO_VT_STRIKE) != 0 {
            let midY = (baseline(y) + (ascent - descent) / 3).rounded()
            ctx.fill(CGRect(x: left, y: midY, width: width, height: lineWidth))
        }
        if cell.flags & UInt8(BOO_VT_OVERLINE) != 0 {
            ctx.fill(CGRect(x: left, y: cellY(y) + geometry.cell.height - lineWidth, width: width, height: lineWidth))
        }
    }

    // CoreGraphics is bottom-up; row 0 sits at the top of the padded area.
    private func cellX(_ x: Int) -> CGFloat { geometry.padding + CGFloat(x) * geometry.cell.width }

    private func cellY(_ y: Int) -> CGFloat {
        geometry.size.height - geometry.padding - CGFloat(y + 1) * geometry.cell.height
    }

    private func baseline(_ y: Int) -> CGFloat {
        let extra = max(0, geometry.cell.height - ascent - descent)
        return (cellY(y) + descent + extra / 2).rounded()
    }

    private func color(_ rgb: UInt32, faint: Bool = false) -> CGColor {
        CGColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255, alpha: faint ? 0.5 : 1)
    }
}
