import CGhostty
import CoreGraphics
import Darwin
import Foundation
import ImageIO

/// Sends an image to a terminal using the Kitty Graphics Protocol.
///
/// Encodes the image as APC escape sequences and writes them directly to the
/// terminal's TTY device. The terminal emulator reads the bytes and renders
/// the image inline — no shell command involved.
///
/// Spec: https://sw.kovidgoyal.net/kitty/graphics-protocol/
enum KittyImageProtocol {

    // MARK: - Public API

    /// Encodes `imagePath` as Kitty APC sequences and writes them directly to
    /// the PTY slave of `shellPID`. Returns false if the image cannot be loaded
    /// or the PTY cannot be opened.
    @discardableResult
    static func sendImage(
        imagePath path: String,
        to shellPID: pid_t,
        terminalSize: ghostty_surface_size_s? = nil
    ) -> Bool {
        guard let (pixels, imgW, imgH) = loadRGBA(path: path) else { return false }
        let (cols, rows) = fitCells(imageWidth: imgW, imageHeight: imgH, terminalSize: terminalSize)
        var payload = buildPayload(pixels: pixels, width: imgW, height: imgH, cols: cols, rows: rows)
        payload += Array("\n\n".utf8)
        return writeToTTY(of: shellPID, bytes: payload)
    }

    // MARK: - TTY write

    /// Writes `bytes` to the TTY of `pid`.
    /// The bytes go through the terminal emulator's VT parser — not the shell's stdin.
    private static func writeToTTY(of pid: pid_t, bytes: [UInt8]) -> Bool {
        guard let ttyPath = ttyPath(for: pid) else { return false }
        let fd = open(ttyPath, O_WRONLY | O_NOCTTY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return bytes.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return false }
            var remaining = bytes.count
            var offset = 0
            while remaining > 0 {
                let n = write(fd, base.advanced(by: offset), remaining)
                if n <= 0 { return false }
                offset += n
                remaining -= n
            }
            return true
        }
    }

    /// Returns `/dev/ttysXXX` for the controlling terminal of `pid`, or nil if the PID is dead/has no TTY.
    static func ttyPath(for pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        let rc = proc_pidinfo(
            pid, PROC_PIDTBSDINFO, 0, &info,
            Int32(MemoryLayout<proc_bsdinfo>.size))
        guard rc > 0 else { return nil }
        guard info.e_tdev != UInt32(bitPattern: -1) else { return nil }
        guard let name = devname(dev_t(info.e_tdev), S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }

    // MARK: - Image loading

    /// Loads an image from disk and returns raw RGBA pixels, width, height.
    static func loadRGBA(path: String) -> ([UInt8], Int, Int)? {
        let url = URL(fileURLWithPath: path)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }

        let w = cgImage.width
        let h = cgImage.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard
            let ctx = CGContext(
                data: &pixels,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (pixels, w, h)
    }

    // MARK: - Cell fitting

    /// Computes the number of columns and rows to request so the image fills the
    /// pane height and derives its width from the image's aspect ratio.
    ///
    /// Strategy: use the full pane height (rows), then compute the proportional
    /// width in columns. If that exceeds the pane width, clamp to pane width and
    /// shrink rows proportionally.
    static func fitCells(
        imageWidth imgW: Int,
        imageHeight imgH: Int,
        terminalSize: ghostty_surface_size_s?
    ) -> (cols: Int?, rows: Int?) {
        guard let ts = terminalSize,
            ts.cell_width_px > 0, ts.cell_height_px > 0,
            ts.columns > 0, ts.rows > 0,
            imgW > 0, imgH > 0
        else { return (nil, nil) }

        let maxCols = max(1, Int(Double(ts.columns) * 0.9))
        let maxRows = Int(ts.rows)
        let cellW = Int(ts.cell_width_px)
        let cellH = Int(ts.cell_height_px)

        // Target: fill the pane height
        let targetRows = maxRows

        // Derive cols from aspect ratio, accounting for non-square cells
        // cols/rows = (imgW/cellW) / (imgH/cellH) = imgW * cellH / (imgH * cellW)
        let targetCols = max(
            1,
            Int(
                (Double(targetRows) * Double(imgW) * Double(cellH)
                    / (Double(imgH) * Double(cellW))).rounded()))

        // If too wide, clamp to pane width and shrink rows proportionally
        if targetCols <= maxCols {
            return (targetCols, targetRows)
        } else {
            let scale = Double(maxCols) / Double(targetCols)
            let finalRows = max(1, Int((Double(targetRows) * scale).rounded()))
            return (maxCols, finalRows)
        }
    }

    // MARK: - Protocol encoding

    /// Builds the full sequence of APC chunks for a 32-bit RGBA image.
    ///
    /// First chunk keys:
    ///   `a=T`  — transmit+display action
    ///   `f=32` — RGBA pixel format
    ///   `s=W,v=H` — image pixel dimensions
    ///   `c=C,r=R` — cell columns/rows to fill (optional, for fitting)
    ///   `m=1|0` — more data / last chunk
    static func buildPayload(
        pixels: [UInt8],
        width: Int,
        height: Int,
        cols: Int?,
        rows: Int?
    ) -> [UInt8] {
        let encoded = Data(pixels).base64EncodedData()
        let chunkSize = 4096

        var result: [UInt8] = []
        result.reserveCapacity(encoded.count + encoded.count / 4)

        var offset = 0
        var isFirst = true

        while offset < encoded.count {
            let end = min(offset + chunkSize, encoded.count)
            let chunk = encoded[offset..<end]
            let more = end < encoded.count ? 1 : 0

            let control: String
            if isFirst {
                var keys = "a=T,f=32,s=\(width),v=\(height)"
                if let c = cols { keys += ",c=\(c)" }
                if let r = rows { keys += ",r=\(r)" }
                keys += ",m=\(more)"
                control = keys
                isFirst = false
            } else {
                control = "m=\(more)"
            }

            // APC: ESC _ G <control> ; <base64-data> ESC backslash
            result += Array("\u{1B}_G".utf8)
            result += Array(control.utf8)
            result += Array(";".utf8)
            result += chunk
            result += Array("\u{1B}\\".utf8)

            offset = end
        }

        return result
    }
}
