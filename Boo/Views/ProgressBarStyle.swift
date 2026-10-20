import Cocoa

/// Draws an OSC 9;4 progress bar: a track with a fill in the state's color.
enum ProgressBarStyle {
    static let height: CGFloat = 2

    static func fillColor(_ progress: TerminalProgress, theme: TerminalTheme) -> NSColor {
        switch progress.state {
        case .normal: return theme.accentColor
        case .error: return theme.error
        case .paused: return theme.warning
        // No percent to show; a softer full bar says "busy".
        case .indeterminate: return theme.focusBorder
        }
    }

    static func draw(_ ctx: CGContext, progress: TerminalProgress, in rect: CGRect, theme: TerminalTheme) {
        ctx.saveGState()
        let track = CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)
        ctx.addPath(track)
        ctx.clip()
        ctx.setFillColor(theme.controlFill.cgColor)
        ctx.fill(rect)
        ctx.setFillColor(fillColor(progress, theme: theme).cgColor)
        ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width * progress.fraction, height: rect.height))
        ctx.restoreGState()
    }
}

/// The dock icon with a bar along its bottom while any tab in any window
/// reports progress.
@MainActor
final class DockProgressTile {
    static let shared = DockProgressTile()

    private var shown: TerminalProgress?
    private lazy var view = DockProgressView()

    func update(_ progress: TerminalProgress?) {
        guard progress?.state != shown?.state || progress?.percent != shown?.percent else { return }
        shown = progress
        let tile = NSApplication.shared.dockTile
        if let progress {
            view.progress = progress
            view.frame = NSRect(origin: .zero, size: tile.size)
            tile.contentView = view
        } else {
            tile.contentView = nil
        }
        tile.display()
    }

    /// Recomputes from every window's workspaces.
    func refresh() {
        let reports = WindowManager.shared.controllers.flatMap { controller in
            controller.appState.workspaces.flatMap(\.progressReports)
        }
        update(TerminalProgress.summary(reports))
    }
}

private final class DockProgressView: NSView {
    var progress: TerminalProgress?

    override func draw(_ dirtyRect: NSRect) {
        NSApplication.shared.applicationIconImage?.draw(in: bounds)
        guard let progress, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let inset = bounds.width * 0.12
        let height = max(bounds.height * 0.07, 6)
        let rect = CGRect(x: inset, y: bounds.height * 0.08, width: bounds.width - inset * 2, height: height)
        // Dock bars sit on arbitrary wallpapers; draw on an opaque dark track.
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
        ctx.fillPath()
        ProgressBarStyle.draw(ctx, progress: progress, in: rect, theme: AppSettings.shared.theme)
    }
}
