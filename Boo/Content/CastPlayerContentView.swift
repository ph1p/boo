import CGhostty
import Cocoa

/// Replays an asciicast recording in a display-only terminal. The terminal's
/// own process stays silent; recorded output is fed straight to the parser.
final class CastPlayerContentView: NSView, ContentViewProtocol {
    let contentType: ContentType = .castPlayer

    var onTitleChanged: ((String) -> Void)?
    var onFocused: (() -> Void)?
    var onCloseRequested: (() -> Void)?

    /// Keeps the pty quiet: no echo of terminal query replies, no prompt.
    static let quietProgram = "/bin/sh -c 'stty -echo; exec tail -f /dev/null'"
    static let speeds: [Double] = [0.25, 0.5, 1, 1.5, 2, 4]
    /// Ghostty resizes the grid on its IO thread; hold output until it has.
    private static let resizeSettle: CFTimeInterval = 0.1
    static let shortcutsHelp =
        "Space play/pause · ←/→ 5s (⇧ 1s) · [ ] previous/next marker · −/+ speed · 0 restart · 1–9 jump"

    private var filePath: String?
    private var currentTitle = "Recording"
    private var playback: CastPlayback?

    private let terminalHost = NSView()
    private let ghosttyView: GhosttyView
    private let bar = NSView()
    private let barRule = NSView()
    private let restartButton = PaneControlButton(symbol: "backward.end.fill", help: "Restart (0)")
    private let playButton = PaneControlButton(symbol: "play.fill", help: "Play (Space)")
    private let prevMarkerButton = PaneControlButton(symbol: "chevron.backward.to.line", help: "Previous Marker ([)")
    private let nextMarkerButton = PaneControlButton(symbol: "chevron.forward.to.line", help: "Next Marker (])")
    private let scrubber = CastScrubber()
    private let timeLabel = NSTextField(labelWithString: "0:00 / 0:00")
    private let speedButton = PlayerTextButton()
    private let messageLabel = NSTextField(labelWithString: "")

    private var timer: Timer?
    private var cursor = 0
    private var playhead: TimeInterval = 0
    private var isPlaying = false
    private var speed: Double = 1
    private var lastTick: CFTimeInterval = 0
    private var settleUntil: CFTimeInterval = 0
    private var needsCatchUp = false
    private var grid: (columns: Int, rows: Int) = (80, 24)

    private static let barHeight: CGFloat = 36

    init(filePath: String?) {
        ghosttyView = GhosttyView(
            workingDirectory: NSHomeDirectory(), launch: LaunchSpec(program: Self.quietProgram))
        super.init(frame: .zero)
        wantsLayer = true
        ghosttyView.isInputLocked = true
        setupViews()
        applyTheme()
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsDidChange), name: .settingsChanged, object: nil)
        if let filePath { load(path: filePath) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Layout

    private func setupViews() {
        terminalHost.wantsLayer = true
        terminalHost.layer?.masksToBounds = true
        terminalHost.addSubview(ghosttyView)
        addSubview(terminalHost)

        bar.wantsLayer = true
        bar.toolTip = Self.shortcutsHelp
        barRule.wantsLayer = true
        addSubview(bar)

        restartButton.onClick = { [weak self] in self?.restart() }
        playButton.onClick = { [weak self] in self?.togglePlay() }
        prevMarkerButton.onClick = { [weak self] in self?.jumpToMarker(forward: false) }
        nextMarkerButton.onClick = { [weak self] in self?.jumpToMarker(forward: true) }
        scrubber.onSeek = { [weak self] time in self?.seek(to: time) }
        speedButton.onClick = { [weak self] in self?.showSpeedMenu() }
        speedButton.title = Self.speedTitle(speed)
        speedButton.toolTip = "Playback Speed (− / +)"

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.alignment = .right

        messageLabel.alignment = .center
        messageLabel.isHidden = true
        addSubview(messageLabel)

        for v in [
            barRule, restartButton, playButton, prevMarkerButton, nextMarkerButton, scrubber, timeLabel, speedButton
        ] as [NSView] {
            bar.addSubview(v)
        }
    }

    static func speedTitle(_ s: Double) -> String {
        s == s.rounded() ? "\(Int(s))×" : "\(s)×"
    }

    override func layout() {
        super.layout()
        let h = Self.barHeight
        bar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: h)
        barRule.frame = CGRect(x: 0, y: h - 1, width: bounds.width, height: 1)
        terminalHost.frame = CGRect(x: 0, y: h, width: bounds.width, height: max(0, bounds.height - h))
        messageLabel.frame = terminalHost.frame.insetBy(dx: 20, dy: 0)
            .divided(atDistance: 40, from: .maxYEdge).slice.offsetBy(dx: 0, dy: -40)

        let midY = (h - 1) / 2
        let side: CGFloat = 24
        var x: CGFloat = 8
        let hasMarkers = !(playback?.markers.isEmpty ?? true)
        prevMarkerButton.isHidden = !hasMarkers
        nextMarkerButton.isHidden = !hasMarkers
        for b in [restartButton, playButton, prevMarkerButton, nextMarkerButton] where !b.isHidden {
            b.frame = CGRect(x: x, y: midY - side / 2, width: side, height: side)
            x += side + 2
        }
        let speedW = max(36, speedButton.fittingSize.width)
        speedButton.frame = CGRect(x: bounds.width - speedW - 8, y: midY - 11, width: speedW, height: 22)
        let labelW =
            ceil(
                (timeLabel.stringValue as NSString).size(withAttributes: [.font: timeLabel.font as Any]).width) + 4
        timeLabel.frame = CGRect(x: speedButton.frame.minX - labelW - 8, y: midY - 8, width: labelW, height: 16)
        scrubber.frame = CGRect(x: x + 8, y: midY - 10, width: max(40, timeLabel.frame.minX - x - 20), height: 20)
        layoutTerminal()
    }

    /// Sizes the terminal to the recording's grid, pinned top-left; a grid
    /// larger than the tab is clipped rather than reflowed.
    private func layoutTerminal() {
        let host = terminalHost.bounds
        guard let size = ghosttyView.gridSize, size.cell_width_px > 0, size.cell_height_px > 0,
            size.columns > 0, size.rows > 0
        else {
            ghosttyView.frame = host
            return
        }
        let scale = window?.backingScaleFactor ?? 2
        let cellW = CGFloat(size.cell_width_px)
        let cellH = CGFloat(size.cell_height_px)
        let padW = max(0, CGFloat(size.width_px) - CGFloat(size.columns) * cellW)
        let padH = max(0, CGFloat(size.height_px) - CGFloat(size.rows) * cellH)
        let w = ((CGFloat(grid.columns) * cellW + padW) / scale).rounded(.up)
        let h = ((CGFloat(grid.rows) * cellH + padH) / scale).rounded(.up)
        let frame = CGRect(x: 0, y: host.height - h, width: w, height: h)
        guard ghosttyView.frame != frame else { return }
        ghosttyView.frame = frame
        settleUntil = CACurrentMediaTime() + Self.resizeSettle
    }

    private func applyGrid(_ next: (columns: Int, rows: Int)) {
        guard next != grid else { return }
        grid = next
        layoutTerminal()
    }

    // MARK: - Loading

    private func load(path: String) {
        filePath = path
        currentTitle = (path as NSString).lastPathComponent
        onTitleChanged?(currentTitle)
        do {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            let pb = try CastPlayback(
                text: text, fallbackIdleLimit: AppSettings.shared.recordingIdleTimeLimit)
            playback = pb
            scrubber.duration = pb.duration
            scrubber.markers = pb.markers
            messageLabel.isHidden = true
            grid = (pb.width, pb.height)
            needsLayout = true
            seek(to: 0)
            setPlaying(true)
        } catch {
            playback = nil
            scrubber.duration = 0
            scrubber.markers = []
            messageLabel.stringValue = "Can't play \(currentTitle): not an asciicast v2 file."
            messageLabel.isHidden = false
            setPlaying(false)
        }
        updateControls()
    }

    // MARK: - Playback

    private func startTimer() {
        guard timer == nil else { return }
        lastTick = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = now - lastTick
        lastTick = now
        guard let pb = playback, now >= settleUntil else { return }
        if needsCatchUp {
            needsCatchUp = false
            let end = pb.dueIndex(at: playhead)
            feed(
                pb.events[0..<end].compactMap {
                    if case .output(let s) = $0.event { return s }
                    return nil
                })
            cursor = end
            updateControls()
            return
        }
        guard isPlaying else { return }
        playhead = min(pb.duration, playhead + dt * speed)
        deliver(pb, upTo: playhead)
        if playhead >= pb.duration, cursor >= pb.events.count { setPlaying(false) }
        updateControls()
    }

    /// Feeds due output in one batch, stopping at a resize so the grid settles first.
    private func deliver(_ pb: CastPlayback, upTo time: TimeInterval) {
        let end = pb.dueIndex(at: time, from: cursor)
        var batch: [String] = []
        while cursor < end {
            let e = pb.events[cursor].event
            cursor += 1
            switch e {
            case .output(let s):
                batch.append(s)
            case .resize(let c, let r):
                feed(batch)
                batch = []
                applyGrid((c, r))
                if CACurrentMediaTime() < settleUntil { return }
            }
        }
        feed(batch)
    }

    private func feed(_ chunks: [String]) {
        guard !chunks.isEmpty else { return }
        ghosttyView.feedOutput(Array(chunks.joined().utf8))
    }

    /// Resets the terminal and replays everything up to `time` at once.
    private func seek(to time: TimeInterval) {
        guard let pb = playback else { return }
        playhead = min(max(0, time), pb.duration)
        cursor = 0
        ghosttyView.feedOutput(Array("\u{1b}c".utf8))
        applyGrid(pb.grid(before: pb.dueIndex(at: playhead)))
        needsCatchUp = true
        updateControls()
    }

    private func setPlaying(_ playing: Bool) {
        isPlaying = playing
        playButton.setSymbol(playing ? "pause.fill" : "play.fill", help: playing ? "Pause (Space)" : "Play (Space)")
        lastTick = CACurrentMediaTime()
    }

    private func updateControls() {
        let duration = playback?.duration ?? 0
        let loaded = playback != nil
        for item in [scrubber, playButton, restartButton, speedButton] as [NSView] {
            item.alphaValue = loaded ? 1 : 0.4
        }
        scrubber.position = playhead
        let text = "\(CastPlayback.formatTime(playhead)) / \(CastPlayback.formatTime(duration))"
        if timeLabel.stringValue != text {
            let widthChanged = text.count != timeLabel.stringValue.count
            timeLabel.stringValue = text
            if widthChanged { needsLayout = true }
        }
    }

    private func togglePlay() {
        guard let pb = playback else { return }
        if !isPlaying, playhead >= pb.duration { seek(to: 0) }
        setPlaying(!isPlaying)
    }

    private func restart() {
        seek(to: 0)
        setPlaying(true)
    }

    private func jumpToMarker(forward: Bool) {
        guard let pb = playback else { return }
        if let m = forward ? pb.marker(after: playhead) : pb.marker(before: playhead) {
            seek(to: m.time)
        } else if !forward {
            seek(to: 0)
        }
    }

    private func setSpeed(_ s: Double) {
        speed = s
        speedButton.title = Self.speedTitle(s)
        needsLayout = true
    }

    /// Steps through `speeds`; -1 slower, +1 faster.
    private func stepSpeed(_ delta: Int) {
        let i = Self.speeds.firstIndex(of: speed) ?? Self.speeds.firstIndex(of: 1) ?? 0
        setSpeed(Self.speeds[min(max(0, i + delta), Self.speeds.count - 1)])
    }

    private func showSpeedMenu() {
        let menu = NSMenu()
        for s in Self.speeds {
            let item = ClosureMenuItem(title: Self.speedTitle(s)) { [weak self] in self?.setSpeed(s) }
            item.state = s == speed ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(
            positioning: menu.items.first { $0.state == .on }, at: NSPoint(x: 0, y: speedButton.bounds.maxY),
            in: speedButton)
    }

    // MARK: - Keys

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        guard mods.isEmpty, playback != nil else { return super.keyDown(with: event) }
        let step: TimeInterval = event.modifierFlags.contains(.shift) ? 1 : 5
        switch event.keyCode {
        case 49: togglePlay()  // space
        case 123: seek(to: playhead - step)  // left
        case 124: seek(to: playhead + step)  // right
        case 115: restart()  // home
        case 119: seek(to: playback?.duration ?? 0)  // end
        default:
            switch event.charactersIgnoringModifiers ?? "" {
            case "k": togglePlay()
            case "j": seek(to: playhead - 10)
            case "l": seek(to: playhead + 10)
            case "[": jumpToMarker(forward: false)
            case "]": jumpToMarker(forward: true)
            case "-", "_": stepSpeed(-1)
            case "+", "=": stepSpeed(1)
            case "0": restart()
            case let c where c.count == 1 && ("1"..."9").contains(c):
                seek(to: (playback?.duration ?? 0) * (Double(c) ?? 0) / 10)
            default: super.keyDown(with: event)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onFocused?()
    }

    // MARK: - ContentViewProtocol

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { startTimer() } else { stopTimer() }
    }

    func activate() {
        window?.makeFirstResponder(self)
        startTimer()
        onFocused?()
    }

    func deactivate() {
        setPlaying(false)
    }

    func cleanup() {
        stopTimer()
        ghosttyView.destroy()
    }

    func saveState() -> ContentState {
        .castPlayer(CastPlayerContentState(title: currentTitle, filePath: filePath ?? ""))
    }

    func restoreState(_ state: ContentState) {
        guard case .castPlayer(let s) = state, !s.filePath.isEmpty, s.filePath != filePath else { return }
        load(path: s.filePath)
    }

    // MARK: - Theme

    @objc private func settingsDidChange(_ note: Notification) {
        guard let raw = note.userInfo?["topic"] as? String, SettingsTopic(rawValue: raw) == .theme else { return }
        applyTheme()
    }

    private func applyTheme() {
        let theme = AppSettings.shared.theme
        layer?.backgroundColor = theme.background.nsColor.cgColor
        bar.layer?.backgroundColor = theme.chromeBg.cgColor
        barRule.layer?.backgroundColor = theme.separator.cgColor
        timeLabel.textColor = theme.textSecondary
        messageLabel.textColor = theme.textSecondary
        for b in [playButton, restartButton, prevMarkerButton, nextMarkerButton] { b.applyTheme() }
        speedButton.applyTheme()
        scrubber.needsDisplay = true
    }
}

// MARK: - Scrubber

/// Timeline track: played part in the accent, marker ticks, and a knob that
/// grows on hover. Click or drag to seek; drags snap to nearby markers.
final class CastScrubber: NSView {
    var onSeek: ((TimeInterval) -> Void)?
    var duration: TimeInterval = 0 { didSet { rebuildToolTips() } }
    var markers: [CastPlayback.Marker] = [] { didSet { rebuildToolTips() } }
    var position: TimeInterval = 0 {
        didSet { if position != oldValue { needsDisplay = true } }
    }

    private var hovered = false { didSet { needsDisplay = true } }
    private var dragging = false
    private var trackingArea: NSTrackingArea?
    private static let inset: CGFloat = 6
    private static let snap: CGFloat = 5

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Position")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var track: NSRect {
        NSRect(x: Self.inset, y: bounds.midY - 2, width: max(0, bounds.width - Self.inset * 2), height: 4)
    }

    private func x(for time: TimeInterval) -> CGFloat {
        guard duration > 0 else { return track.minX }
        return track.minX + track.width * CGFloat(min(max(0, time / duration), 1))
    }

    private func time(at x: CGFloat) -> TimeInterval {
        guard track.width > 0 else { return 0 }
        if let near = markers.first(where: { abs(self.x(for: $0.time) - x) <= Self.snap }) { return near.time }
        return duration * Double(min(max(0, (x - track.minX) / track.width), 1))
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = AppSettings.shared.theme
        let track = self.track
        theme.controlFill.setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        let head = x(for: position)
        theme.accentColor.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: track.minX, y: track.minY, width: head - track.minX, height: track.height),
            xRadius: 2, yRadius: 2
        ).fill()
        for m in markers {
            let mx = x(for: m.time)
            (m.time <= position ? theme.chromeBg : theme.warning).setFill()
            NSBezierPath(
                roundedRect: NSRect(x: mx - 1.5, y: track.midY - 4, width: 3, height: 8), xRadius: 1.5, yRadius: 1.5
            ).fill()
        }
        let r: CGFloat = hovered || dragging ? 6 : 4.5
        let knob = NSRect(x: head - r, y: track.midY - r, width: r * 2, height: r * 2)
        theme.accentColor.setFill()
        NSBezierPath(ovalIn: knob).fill()
        theme.chromeBg.setStroke()
        let ring = NSBezierPath(ovalIn: knob.insetBy(dx: 0.75, dy: 0.75))
        ring.lineWidth = 1.5
        ring.stroke()
    }

    private func rebuildToolTips() {
        removeAllToolTips()
        for (i, m) in markers.enumerated() {
            let mx = x(for: m.time)
            let label = m.label.isEmpty ? "Marker \(i + 1)" : m.label
            addToolTip(
                NSRect(x: mx - Self.snap, y: 0, width: Self.snap * 2, height: bounds.height),
                owner: "\(label) · \(CastPlayback.formatTime(m.time))" as NSString, userData: nil)
        }
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { rebuildToolTips() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func mouseDown(with event: NSEvent) {
        guard duration > 0 else { return }
        dragging = true
        seek(event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        seek(event)
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
        needsDisplay = true
    }

    private func seek(_ event: NSEvent) {
        let t = time(at: convert(event.locationInWindow, from: nil).x)
        position = t
        onSeek?(t)
    }

    override func accessibilityValue() -> Any? { CastPlayback.formatTime(position) }
    override func accessibilityPerformIncrement() -> Bool {
        onSeek?(position + 5)
        return true
    }
    override func accessibilityPerformDecrement() -> Bool {
        onSeek?(position - 5)
        return true
    }
}

/// Text segment with the pane-controls hover treatment; the player's speed menu.
final class PlayerTextButton: PaneControlItem {
    private let label = NSTextField(labelWithString: "")

    var title: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            setAccessibilityLabel("Speed \(newValue)")
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.alignment = .center
        addSubview(label)
        applyTheme()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var fittingSize: NSSize {
        NSSize(width: ceil(label.intrinsicContentSize.width) + 16, height: 22)
    }

    func applyTheme() { hoverChanged() }

    override func hoverChanged() {
        let theme = AppSettings.shared.theme
        label.textColor = hovered ? theme.chromeText : theme.textSecondary
        layer?.backgroundColor = (hovered ? theme.hoverFill : theme.subtleFill).cgColor
    }

    override func layout() {
        super.layout()
        let h = label.intrinsicContentSize.height
        label.frame = NSRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
    }
}
