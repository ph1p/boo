import Cocoa

/// What the window backdrop and the sidebar island are made of. One global
/// choice; terminals stay opaque unless `translucentTerminals` is on.
enum WindowMaterial: Int, CaseIterable {
    /// Opaque theme colours, the default.
    case off = 0
    /// The desktop shows through a blurred `NSVisualEffectView`, tinted with
    /// the theme's backdrop and chrome colours.
    case vibrancy = 1

    var label: String {
        switch self {
        case .off: return "Off"
        case .vibrancy: return "Vibrancy"
        }
    }

    var isTranslucent: Bool { self != .off }

    /// Reads a stored raw value. Any non-zero value is vibrancy: a removed
    /// Glass mode was stored as 2.
    init(storedValue: Int) {
        self = storedValue == 0 ? .off : .vibrancy
    }

    static var current: WindowMaterial { AppSettings.shared.windowMaterial }

    /// Opacity of the theme backdrop laid over the blur. High enough that the
    /// chrome keeps the theme's colour, so workspace and status colours picked
    /// for that backdrop stay legible; low enough for the desktop to read.
    static let backdropTint: CGFloat = 0.65

    /// Opacity of the sidebar's own fill, stacked on the backdrop tint. The
    /// island reads as the theme's chrome colour, a step off the backdrop.
    static let sidebarTint: CGFloat = 0.6

    /// Opacity of the settings window's detail island and its cards. Higher
    /// than the sidebar: the page carries body text and controls, so it keeps
    /// more of the theme fill while the blur still reads through.
    static let contentTint: CGFloat = 0.72

    /// Multiplier on workspace pill and group tray fills over the blur. Their
    /// opaque-mode alphas (0.06 at rest) are tuned for a flat backdrop and
    /// vanish against a busy desktop behind the blur.
    static let pillFillBoost: CGFloat = 2

    /// Alpha of the hairline a resting workspace pill gets over the blur, so
    /// each pill keeps an edge where its faint fill alone would not.
    static let pillHairlineAlpha: CGFloat = 0.22

    /// Opacity of a terminal's default background while terminals are
    /// translucent. Text stays crisp; the blur reads through the empty cells.
    static let terminalOpacity: CGFloat = 0.75

    /// Whether terminals let the material through right now: the toggle is on
    /// and the window itself is translucent.
    static var terminalsTranslucent: Bool {
        current.isTranslucent && AppSettings.shared.translucentTerminals
    }
}

extension TerminalTheme {
    /// Fill for views that paint the gaps between islands (split dividers,
    /// scroll fades). Clear when a material shows through the backdrop.
    var chromeBackdropFill: NSColor {
        WindowMaterial.current.isTranslucent ? .clear : surfaceBackdrop
    }

    /// Fill for views inside the sidebar island. Clear when a material shows
    /// through: the island itself carries the tint, and stacking translucent
    /// fills would darken each nested view.
    var chromeSidebarFill: NSColor {
        WindowMaterial.current.isTranslucent ? .clear : surfaceChrome
    }

    /// Opaque fill under a control that floats over terminals (the expanded
    /// workspace pill). With a material it approximates the sidebar island as
    /// seen over the tinted backdrop, so the pill looks like the chrome it
    /// slid out of rather than a solid block.
    var chromeFloatingFill: NSColor {
        guard WindowMaterial.current.isTranslucent else { return surfaceChrome }
        return TerminalTheme.blend(surfaceChrome, over: surfaceBackdrop, alpha: WindowMaterial.sidebarTint)
    }

    /// Fill behind a pane: the terminal background, at `terminalOpacity` while
    /// terminals are translucent. Ghostty then draws its default background
    /// clear, so this fill is the only one and the alpha does not stack.
    var paneFill: NSColor {
        let fill = background.surfaceColor
        return WindowMaterial.terminalsTranslucent
            ? fill.withAlphaComponent(WindowMaterial.terminalOpacity) : fill
    }

    /// Fill a pane paints in `draw(_:)` over its own layer (tab bar, tab
    /// column, their fades). Clear while terminals are translucent: the layer
    /// already carries `paneFill`, and painting it again would double the alpha.
    var paneDrawFill: NSColor {
        WindowMaterial.terminalsTranslucent ? .clear : background.surfaceColor
    }
}

/// Installs and updates the material views of a main window and its floating
/// islands, following the current `WindowMaterial`.
@MainActor
enum WindowMaterialStyler {
    private static let backdropID = NSUserInterfaceItemIdentifier("boo.windowMaterial.backdrop")
    private static let blurID = NSUserInterfaceItemIdentifier("boo.windowMaterial.blur")

    /// Applies the material to the window, its content view and the sidebar
    /// island. Safe to call repeatedly: views are added or removed as needed.
    static func apply(theme: TerminalTheme, window: NSWindow, sidebar: NSView?) {
        guard let contentView = window.contentView else { return }
        contentView.wantsLayer = true

        if WindowMaterial.current.isTranslucent {
            window.isOpaque = false
            window.backgroundColor = .clear
            contentView.layer?.backgroundColor =
                theme.surfaceBackdrop.withAlphaComponent(WindowMaterial.backdropTint).cgColor
            // Full-window blur behind every other subview. The window's appearance
            // (set from the theme) picks a light or dark blur.
            installEffect(backdropID, material: .underWindowBackground, in: contentView)
        } else {
            window.isOpaque = true
            window.backgroundColor = theme.surfaceBackdrop
            contentView.layer?.backgroundColor = theme.surfaceBackdrop.cgColor
            removeEffect(backdropID, from: contentView)
        }

        if let sidebar {
            // The window blur already sits behind the sidebar: no blur of its own.
            styleIsland(sidebar, fill: theme.surfaceChrome, border: theme.borderChrome, ownBlur: false)
        }
    }

    /// Styles a rounded island: an opaque `fill`, or the fill at `sidebarTint`
    /// over the blur. Both keep the hairline border, so islands match in either
    /// mode. `ownBlur` adds a blur for islands in their own window (palettes,
    /// panels), which do not sit over the main window's backdrop blur.
    static func styleIsland(_ view: NSView, fill: NSColor, border: NSColor, ownBlur: Bool) {
        IslandMetrics.round(view, borderColor: border)
        let translucent = WindowMaterial.current.isTranslucent
        if translucent && ownBlur {
            installEffect(blurID, material: .popover, in: view)
        } else {
            removeEffect(blurID, from: view)
        }
        view.layer?.backgroundColor =
            (translucent ? fill.withAlphaComponent(WindowMaterial.sidebarTint) : fill).cgColor
    }

    /// A blur at the bottom of `view`, added once. It stays active when the
    /// window is unfocused: the inactive material is a flat grey that drops the
    /// theme tint and reads as a different window.
    private static func installEffect(
        _ id: NSUserInterfaceItemIdentifier, material: NSVisualEffectView.Material, in view: NSView
    ) {
        guard !view.subviews.contains(where: { $0.identifier == id }) else { return }
        let effect = NSVisualEffectView()
        effect.identifier = id
        effect.material = material
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.frame = view.bounds
        effect.autoresizingMask = [.width, .height]
        view.addSubview(effect, positioned: .below, relativeTo: nil)
    }

    private static func removeEffect(_ id: NSUserInterfaceItemIdentifier, from view: NSView) {
        view.subviews.first { $0.identifier == id }?.removeFromSuperview()
    }
}
