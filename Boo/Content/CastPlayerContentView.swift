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
    static let speeds: [Double] = [0.5, 1, 2, 4]
    /// Ghostty resizes the grid on its IO thread; hold output until it has.
    private static let resizeSettle: CFTimeInterval = 0.1

    private var filePath: String?
    private var currentTitle = "Recording"
    private var playback: CastPlayback?

    private let terminalHost = NSView()
    private let ghosttyView: GhosttyView
    private let bar = NSView()
    private let playButton = NSButton()
    private let restartButton = NSButton()
    private let slider = NSSlider()
    private let timeLabel = NSTextField(labelWithString: "0:00 / 0:00")
    private let speedPopup = NSPopUpButton()
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

    private static let barHeight: CGFloat = 34

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
        addSubview(bar)

        func symbolButton(_ button: NSButton, _ symbol: String, _ label: String, _ action: Selector) {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.target = self
            button.action = action
            button.toolTip = label
            button.setAccessibilityLabel(label)
        }
        symbolButton(playButton, "play.fill", "Play", #selector(togglePlay))
        symbolButton(restartButton, "backward.end.fill", "Restart", #selector(restart))

        slider.minValue = 0
        slider.maxValue = 1
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.setAccessibilityLabel("Position")

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.alignment = .right

        speedPopup.controlSize = .small
        speedPopup.font = .systemFont(ofSize: 11)
        for s in Self.speeds { speedPopup.addItem(withTitle: Self.speedTitle(s)) }
        speedPopup.selectItem(at: Self.speeds.firstIndex(of: 1) ?? 0)
        speedPopup.target = self
        speedPopup.action = #selector(speedChanged)
        speedPopup.setAccessibilityLabel("Speed")

        messageLabel.alignment = .center
        messageLabel.isHidden = true
        addSubview(messageLabel)

        for v in [playButton, restartButton, slider, timeLabel, speedPopup] { bar.addSubview(v) }
    }

    static func speedTitle(_ s: Double) -> String {
        s == s.rounded() ? "\(Int(s))×" : "\(s)×"
    }

    override func layout() {
        super.layout()
        let h = Self.barHeight
        bar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: h)
        terminalHost.frame = CGRect(x: 0, y: h, width: bounds.width, height: max(0, bounds.height - h))
        messageLabel.frame = terminalHost.frame.insetBy(dx: 20, dy: 0)
            .divided(atDistance: 40, from: .maxYEdge).slice.offsetBy(dx: 0, dy: -40)

        let midY = h / 2
        var x: CGFloat = 8
        for b in [restartButton, playButton] {
            b.frame = CGRect(x: x, y: midY - 12, width: 24, height: 24)
            x += 28
        }
        let popupW: CGFloat = 64
        let labelW: CGFloat = 96
        speedPopup.frame = CGRect(x: bounds.width - popupW - 8, y: midY - 11, width: popupW, height: 22)
        timeLabel.frame = CGRect(x: speedPopup.frame.minX - labelW - 6, y: midY - 8, width: labelW, height: 16)
        slider.frame = CGRect(x: x + 4, y: midY - 10, width: max(40, timeLabel.frame.minX - x - 12), height: 20)
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
            let pb = try CastPlayback(text: text)
            playback = pb
            messageLabel.isHidden = true
            grid = (pb.width, pb.height)
            needsLayout = true
            seek(to: 0)
            setPlaying(true)
        } catch {
            playback = nil
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
            feed(pb.events[0..<end].compactMap {
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
        let symbol = playing ? "pause.fill" : "play.fill"
        let label = playing ? "Pause" : "Play"
        playButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        playButton.toolTip = label
        playButton.setAccessibilityLabel(label)
        lastTick = CACurrentMediaTime()
    }

    private func updateControls() {
        let duration = playback?.duration ?? 0
        slider.isEnabled = playback != nil
        playButton.isEnabled = playback != nil
        restartButton.isEnabled = playback != nil
        slider.maxValue = max(duration, 0.001)
        slider.doubleValue = playhead
        timeLabel.stringValue = "\(CastPlayback.formatTime(playhead)) / \(CastPlayback.formatTime(duration))"
    }

    @objc private func togglePlay() {
        guard let pb = playback else { return }
        if !isPlaying, playhead >= pb.duration { seek(to: 0) }
        setPlaying(!isPlaying)
    }

    @objc private func restart() {
        seek(to: 0)
        setPlaying(true)
    }

    @objc private func sliderMoved() {
        seek(to: slider.doubleValue)
    }

    @objc private func speedChanged() {
        let i = speedPopup.indexOfSelectedItem
        guard Self.speeds.indices.contains(i) else { return }
        speed = Self.speeds[i]
    }

    // MARK: - Keys

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: togglePlay()  // space
        case 123: seek(to: playhead - 5)  // left
        case 124: seek(to: playhead + 5)  // right
        default: super.keyDown(with: event)
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
        timeLabel.textColor = theme.chromeMuted
        messageLabel.textColor = theme.chromeMuted
        for b in [playButton, restartButton] { b.contentTintColor = theme.chromeText }
    }
}
