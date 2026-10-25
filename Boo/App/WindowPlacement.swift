import AppKit

/// A window frame plus the display it sat on, so a restore can follow that
/// display when the arrangement changed or it was unplugged in between.
struct WindowPlacement: Codable, Equatable, Sendable {
    /// Frame in global screen coordinates: [x, y, width, height].
    var frame: [Double]
    /// Display UUID of the screen holding most of the frame.
    var screenID: String?
    /// That screen's frame when captured: [x, y, width, height].
    var screenFrame: [Double]?

    var frameRect: NSRect? { Self.rect(frame) }
    var screenFrameRect: NSRect? { screenFrame.flatMap(Self.rect) }

    init(frame: NSRect, screen: PlacementScreen?) {
        self.frame = Self.array(frame)
        self.screenID = screen?.id
        self.screenFrame = screen.map { Self.array($0.frame) }
    }

    init(frame: [Double], screenID: String? = nil, screenFrame: [Double]? = nil) {
        self.frame = frame
        self.screenID = screenID
        self.screenFrame = screenFrame
    }

    static func rect(_ values: [Double]) -> NSRect? {
        guard values.count == 4, values[2] > 0, values[3] > 0 else { return nil }
        return NSRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    static func array(_ rect: NSRect) -> [Double] {
        [rect.origin.x, rect.origin.y, rect.width, rect.height].map { Double($0) }
    }
}

/// A connected display as placement sees it: plain values so resolving is testable.
struct PlacementScreen: Equatable {
    let id: String?
    let frame: NSRect
    let visibleFrame: NSRect

    init(id: String?, frame: NSRect, visibleFrame: NSRect) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
    }

    init(_ screen: NSScreen) {
        self.init(id: screen.displayUUID, frame: screen.frame, visibleFrame: screen.visibleFrame)
    }

    /// Connected screens, menu-bar screen first.
    @MainActor static var current: [PlacementScreen] { NSScreen.screens.map(PlacementScreen.init) }
}

extension NSScreen {
    /// Stable across reboots and rearranging, unlike the CGDirectDisplayID.
    var displayUUID: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
            let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

enum WindowPlacementResolver {
    /// The screen holding most of `frame`, nil when it touches none.
    static func screen(for frame: NSRect, in screens: [PlacementScreen]) -> PlacementScreen? {
        let best = screens.max { overlap(frame, $0.frame) < overlap(frame, $1.frame) }
        guard let best, overlap(frame, best.frame) > 0 else { return nil }
        return best
    }

    static func capture(_ frame: NSRect, in screens: [PlacementScreen]) -> WindowPlacement {
        WindowPlacement(frame: frame, screen: screen(for: frame, in: screens))
    }

    /// Whether the placement's own display is connected.
    static func isScreenConnected(_ placement: WindowPlacement, in screens: [PlacementScreen]) -> Bool {
        guard let id = placement.screenID else { return false }
        return screens.contains { $0.id == id }
    }

    /// Frame to show `placement` at, fully inside one screen's visible area.
    /// `onSavedScreen` is false when its display is gone and the frame landed
    /// elsewhere; placements saved without a display count as on it.
    static func resolve(
        _ placement: WindowPlacement, in screens: [PlacementScreen]
    ) -> (frame: NSRect, onSavedScreen: Bool)? {
        guard let frame = placement.frameRect, let main = screens.first else { return nil }
        if let id = placement.screenID, let screen = screens.first(where: { $0.id == id }) {
            // Same display, maybe moved in the arrangement: keep the offset within it.
            var moved = frame
            if let saved = placement.screenFrameRect {
                moved.origin.x += screen.frame.minX - saved.minX
                moved.origin.y += screen.frame.minY - saved.minY
            }
            return (fit(moved, into: screen.visibleFrame), true)
        }
        let onSaved = placement.screenID == nil
        let best = screens.max { overlap(frame, $0.visibleFrame) < overlap(frame, $1.visibleFrame) }
        if let best, overlap(frame, best.visibleFrame) > 0 {
            return (fit(frame, into: best.visibleFrame), onSaved)
        }
        // Nowhere near a connected screen: center on the menu-bar screen.
        let visible = main.visibleFrame
        var centered = frame
        centered.origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
        return (fit(centered, into: visible), onSaved)
    }

    /// Shrinks `frame` to `visible` if needed and slides it fully inside.
    static func fit(_ frame: NSRect, into visible: NSRect) -> NSRect {
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height)
        let x = min(max(frame.minX, visible.minX), visible.maxX - width)
        let y = min(max(frame.minY, visible.minY), visible.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private static func overlap(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }
}
