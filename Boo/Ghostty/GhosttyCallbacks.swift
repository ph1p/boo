import CGhostty
import Cocoa

// C-compatible callback functions
func ghosttyWakeup(_ userdata: UnsafeMutableRawPointer?) {
    DispatchQueue.main.async {
        guard let app = GhosttyRuntime.shared.app else { return }
        ghostty_app_tick(app)
    }
}

/// Post a `.ghosttyAction` scoped to the window hosting `view` (nil → active window).
private func postWindowAction(from view: GhosttyView?, _ userInfo: [String: String]) {
    DispatchQueue.main.async { [weak view] in
        NotificationCenter.default.post(name: .ghosttyAction, object: view?.window, userInfo: userInfo)
    }
}

func ghosttyAction(_ app: ghostty_app_t, _ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool {
    // Get the GhosttyView from the surface's userdata
    func viewFromTarget() -> GhosttyView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
            let surface = target.target.surface,
            let userdata = ghostty_surface_userdata(surface)
        else { return nil }
        return Unmanaged<GhosttyView>.fromOpaque(userdata).takeUnretainedValue()
    }

    switch action.tag {
    case GHOSTTY_ACTION_PWD:
        let path = String(cString: action.action.pwd.pwd)
        guard let view = viewFromTarget() else { return false }
        DispatchQueue.main.async { [weak view] in
            view?.onPwdChanged?(path)
        }
        return true

    case GHOSTTY_ACTION_SET_TITLE:
        let title = String(cString: action.action.set_title.title)
        guard let view = viewFromTarget() else { return false }
        // Intercept BOO_LS: prefixed titles — directory listings, not real titles.
        if title.hasPrefix("BOO_LS:") {
            let payload = String(title.dropFirst("BOO_LS:".count))
            if let colonIdx = payload.firstIndex(of: ":") {
                let path = String(payload[..<colonIdx])
                let output = String(payload[payload.index(after: colonIdx)...])
                DispatchQueue.main.async { [weak view] in
                    view?.onDirectoryListing?(path, output)
                }
            }
            return true
        }

        // Intercept BOO_CMD: prefixed SET_TITLE events from Boo's shell integration scripts.
        // cmd_end is handled natively via GHOSTTY_ACTION_COMMAND_FINISHED (OSC 133) — only
        // cmd_start remains here, used to set isCommandRunning on the tab.
        if title.hasPrefix("BOO_CMD:") {
            let payload = String(title.dropFirst("BOO_CMD:".count))
            if let semicolonIdx = payload.firstIndex(of: ";") {
                let action = String(payload[..<semicolonIdx])
                let data = String(payload[payload.index(after: semicolonIdx)...])
                if action == "cmd_start" {
                    DispatchQueue.main.async { [weak view] in
                        view?.atBooPrompt = false
                        view?.commandHistory.start(data)
                        view?.onCommandStart?(data)
                        view?.onPromptMarksChanged?()
                    }
                } else if action == "cmd_end" {
                    // Sent at every prompt, the first one included.
                    DispatchQueue.main.async { [weak view] in view?.atBooPrompt = true }
                }
            }
            return true
        }

        DispatchQueue.main.async { [weak view] in
            view?.onTitleChanged?(title)
        }
        return true

    case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
        guard let view = viewFromTarget() else { return false }
        DispatchQueue.main.async { [weak view] in
            view?.onProcessExited?()
        }
        return true

    case GHOSTTY_ACTION_COMMAND_FINISHED:
        guard let view = viewFromTarget() else { return false }
        let exitCode = Int32(action.action.command_finished.exit_code)
        let duration = action.action.command_finished.duration
        DispatchQueue.main.async { [weak view] in
            view?.commandHistory.finish(exitCode: exitCode, durationNanos: duration)
            view?.onCommandEnd?(exitCode)
            view?.onPromptMarksChanged?()
        }
        return true

    case GHOSTTY_ACTION_PROGRESS_REPORT:
        guard let view = viewFromTarget() else { return false }
        let raw = action.action.progress_report
        let report: TerminalProgress.Report
        switch raw.state {
        case GHOSTTY_PROGRESS_STATE_SET: report = .set
        case GHOSTTY_PROGRESS_STATE_ERROR: report = .error
        case GHOSTTY_PROGRESS_STATE_INDETERMINATE: report = .indeterminate
        case GHOSTTY_PROGRESS_STATE_PAUSE: report = .pause
        default: report = .remove
        }
        let percent = Int(raw.progress)
        DispatchQueue.main.async { [weak view] in
            view?.onProgressReport?(report, percent)
        }
        return true

    case GHOSTTY_ACTION_RING_BELL:
        guard let view = viewFromTarget() else { return false }
        DispatchQueue.main.async { [weak view] in
            view?.onBell?()
        }
        return true

    case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
        guard let view = viewFromTarget() else { return false }
        let notifTitle = String(cString: action.action.desktop_notification.title)
        let notifBody = String(cString: action.action.desktop_notification.body)
        DispatchQueue.main.async { [weak view] in
            view?.onDesktopNotification?(notifTitle, notifBody)
        }
        return true

    // Window management actions — forward to MainWindowController via notification.
    // `object` is the surface's window so only that window reacts; nil (app-level
    // action, no surface) goes to the active window.
    case GHOSTTY_ACTION_NEW_SPLIT:
        let direction = action.action.new_split
        let vertical = direction == GHOSTTY_SPLIT_DIRECTION_RIGHT || direction == GHOSTTY_SPLIT_DIRECTION_LEFT
        postWindowAction(
            from: viewFromTarget(), ["action": "new_split", "direction": vertical ? "vertical" : "horizontal"])
        return true

    case GHOSTTY_ACTION_GOTO_SPLIT:
        let dir = action.action.goto_split
        let dirStr: String
        switch dir {
        case GHOSTTY_GOTO_SPLIT_PREVIOUS: dirStr = "previous"
        case GHOSTTY_GOTO_SPLIT_NEXT: dirStr = "next"
        case GHOSTTY_GOTO_SPLIT_LEFT: dirStr = "left"
        case GHOSTTY_GOTO_SPLIT_RIGHT: dirStr = "right"
        case GHOSTTY_GOTO_SPLIT_UP: dirStr = "up"
        case GHOSTTY_GOTO_SPLIT_DOWN: dirStr = "down"
        default: return false
        }
        postWindowAction(from: viewFromTarget(), ["action": "goto_split", "direction": dirStr])
        return true

    case GHOSTTY_ACTION_RESIZE_SPLIT:
        let resize = action.action.resize_split
        let dirStr: String
        switch resize.direction {
        case GHOSTTY_RESIZE_SPLIT_LEFT: dirStr = "left"
        case GHOSTTY_RESIZE_SPLIT_RIGHT: dirStr = "right"
        case GHOSTTY_RESIZE_SPLIT_UP: dirStr = "up"
        case GHOSTTY_RESIZE_SPLIT_DOWN: dirStr = "down"
        default: return false
        }
        postWindowAction(
            from: viewFromTarget(),
            ["action": "resize_split", "direction": dirStr, "amount": String(resize.amount)])
        return true

    case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
        postWindowAction(from: viewFromTarget(), ["action": "toggle_split_zoom"])
        return true

    case GHOSTTY_ACTION_EQUALIZE_SPLITS:
        postWindowAction(from: viewFromTarget(), ["action": "equalize_splits"])
        return true

    case GHOSTTY_ACTION_CLOSE_TAB:
        postWindowAction(from: viewFromTarget(), ["action": "close_surface"])
        return true

    case GHOSTTY_ACTION_NEW_TAB:
        postWindowAction(from: viewFromTarget(), ["action": "new_tab"])
        return true

    case GHOSTTY_ACTION_NEW_WINDOW:
        postWindowAction(from: viewFromTarget(), ["action": "new_window"])
        return true

    case GHOSTTY_ACTION_TOGGLE_FULLSCREEN:
        postWindowAction(from: viewFromTarget(), ["action": "toggle_fullscreen"])
        return true

    case GHOSTTY_ACTION_CLOSE_WINDOW:
        postWindowAction(from: viewFromTarget(), ["action": "close_window"])
        return true

    case GHOSTTY_ACTION_QUIT:
        DispatchQueue.main.async {
            NSApplication.shared.terminate(nil)
        }
        return true

    case GHOSTTY_ACTION_OPEN_CONFIG:
        postWindowAction(from: viewFromTarget(), ["action": "open_settings"])
        return true

    case GHOSTTY_ACTION_RELOAD_CONFIG:
        DispatchQueue.main.async {
            GhosttyRuntime.shared.reloadConfig()
        }
        return true

    case GHOSTTY_ACTION_OPEN_URL:
        let openURL = action.action.open_url
        let urlPtr = openURL.url
        let urlString: String
        if openURL.len > 0 {
            urlString = urlPtr.withMemoryRebound(to: UInt8.self, capacity: Int(openURL.len)) {
                String(decoding: UnsafeBufferPointer(start: $0, count: Int(openURL.len)), as: UTF8.self)
            }
        } else {
            urlString = String(cString: urlPtr)
        }
        guard urlString.hasPrefix("http://") || urlString.hasPrefix("https://") else { return false }
        guard let url = URL(string: urlString) else { return false }
        let view = viewFromTarget()
        DispatchQueue.main.async { [weak view] in
            NotificationCenter.default.post(
                name: .ghosttyOpenURL,
                object: view?.window,
                userInfo: ["url": url]
            )
        }
        return true

    case GHOSTTY_ACTION_SCROLLBAR:
        let sb = action.action.scrollbar
        guard let view = viewFromTarget() else { return false }
        let scrollbar = GhosttyView.GhosttyScrollbar(
            total: Int(sb.total), offset: Int(sb.offset), len: Int(sb.len))
        DispatchQueue.main.async { [weak view] in
            view?.scrollbar = scrollbar
            view?.onScrollbarChanged?(scrollbar)
        }
        return true

    case GHOSTTY_ACTION_START_SEARCH:
        let needle = String(cString: action.action.start_search.needle)
        guard let view = viewFromTarget() else { return false }
        DispatchQueue.main.async { [weak view] in
            view?.onSearchRequested?(needle)
        }
        return true

    case GHOSTTY_ACTION_END_SEARCH:
        guard let view = viewFromTarget() else { return false }
        DispatchQueue.main.async { [weak view] in
            view?.onSearchEnded?()
        }
        return true

    case GHOSTTY_ACTION_SEARCH_TOTAL:
        let total = Int(action.action.search_total.total)
        guard let view = viewFromTarget() else { return false }
        DispatchQueue.main.async { [weak view] in
            view?.onSearchTotal?(total)
        }
        return true

    case GHOSTTY_ACTION_SEARCH_SELECTED:
        let selected = Int(action.action.search_selected.selected)
        guard let view = viewFromTarget() else { return false }
        DispatchQueue.main.async { [weak view] in
            view?.onSearchSelected?(selected)
        }
        return true

    default:
        return false
    }
}

func ghosttyReadClipboard(
    _ userdata: UnsafeMutableRawPointer?, _ clipboard: ghostty_clipboard_e, _ state: UnsafeMutableRawPointer,
    _ mimes: UnsafePointer<UnsafePointer<CChar>>, _ mimesLen: Int, _ list: Bool
) -> ghostty_clipboard_read_result_e {
    guard clipboard == GHOSTTY_CLIPBOARD_STANDARD else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
    guard let surface = userdata.flatMap({ Unmanaged<GhosttyView>.fromOpaque($0).takeUnretainedValue().surface })
    else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }

    // Boo only serves text. Ghostty normalizes text-like MIME requests to
    // "text/plain", so anything else (e.g. Kitty image reads) is unavailable.
    let wantsText = (0..<mimesLen).contains { i in
        String(cString: mimes[i]) == "text/plain"
    }
    let str = NSPasteboard.general.ghosttyStringContents
    let text = wantsText ? str : nil
    guard text != nil || list else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }

    // Ghostty slices `data[0..<len]` without a nil check, so even an empty
    // string needs a real (NUL-terminated) buffer.
    guard let data = strdup(text ?? "") else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
    defer { free(data) }
    let available: [String] = list && str != nil ? ["text/plain"] : []
    "text/plain".withCString { mime in
        let contents =
            text == nil ? [] : [ghostty_clipboard_content_s(mime: mime, data: data, len: strlen(data))]
        withCStringArray(available) { avail in
            contents.withUnsafeBufferPointer { contentsBuf in
                var complete = ghostty_clipboard_complete_s(
                    contents: contentsBuf.baseAddress, contents_len: contentsBuf.count,
                    available: avail.baseAddress, available_len: avail.count,
                    confirmed: false, remember: false)
                ghostty_surface_complete_clipboard_request(surface, &complete, state)
            }
        }
    }
    return GHOSTTY_CLIPBOARD_READ_STARTED
}

/// Calls `body` with a temporary C array of NUL-terminated copies of `strings`.
private func withCStringArray<R>(
    _ strings: [String], _ body: (UnsafeBufferPointer<UnsafePointer<CChar>>) -> R
) -> R {
    let copies = strings.compactMap { strdup($0) }
    defer { for copy in copies { free(copy) } }
    return copies.map { UnsafePointer($0) }.withUnsafeBufferPointer(body)
}

func ghosttyConfirmReadClipboard(
    _ userdata: UnsafeMutableRawPointer?, _ confirm: UnsafePointer<ghostty_clipboard_confirm_s>,
    _ state: UnsafeMutableRawPointer, _ request: ghostty_clipboard_request_e
) {
    // Reached for pastes that paste protection flags and for OSC 52 reads
    // (clipboard-read = ask). Every path must complete or deny `state`, or the
    // request leaks.
    guard let userdata else { return }
    let view = Unmanaged<GhosttyView>.fromOpaque(userdata).takeUnretainedValue()
    guard let surface = view.surface else { return }
    guard request == GHOSTTY_CLIPBOARD_REQUEST_PASTE || request == GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ
    else {
        ghostty_surface_deny_clipboard_request(surface, state)
        return
    }
    // The confirm payload is borrowed: copy what the completion needs now.
    let c = confirm.pointee
    var contents: [(mime: String, data: Data)] = []
    for i in 0..<c.contents_len {
        guard let content = c.contents?[i] else { continue }
        let mime = content.mime
        let data = content.len > 0 ? Data(bytes: content.data, count: content.len) : Data()
        contents.append((String(cString: mime), data))
    }
    var available: [String] = []
    for i in 0..<c.available_len {
        if let name = c.available?[i] { available.append(String(cString: name)) }
    }
    let canRemember = c.can_remember
    let isPaste = request == GHOSTTY_CLIPBOARD_REQUEST_PASTE
    let state = UInt(bitPattern: state)

    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            let text = contents.first { $0.mime == "text/plain" }.flatMap { String(data: $0.data, encoding: .utf8) }
            ClipboardConfirmation.ask(isPaste: isPaste, text: text ?? "", canRemember: canRemember, in: view) {
                allowed, remember in
                guard let surface = view.surface else { return }
                guard let state = UnsafeMutableRawPointer(bitPattern: state) else { return }
                guard allowed else {
                    ghostty_surface_deny_clipboard_request(surface, state)
                    return
                }
                let buffers = contents.map { item in
                    item.data.withUnsafeBytes { raw -> UnsafeMutablePointer<CChar> in
                        let copy = UnsafeMutablePointer<CChar>.allocate(capacity: raw.count + 1)
                        raw.copyBytes(to: UnsafeMutableRawBufferPointer(start: copy, count: raw.count))
                        copy[raw.count] = 0
                        return copy
                    }
                }
                defer { for buffer in buffers { buffer.deallocate() } }
                withCStringArray(contents.map(\.mime)) { mimes in
                    let items = zip(mimes, zip(buffers, contents)).map { mime, pair in
                        ghostty_clipboard_content_s(mime: mime, data: pair.0, len: pair.1.data.count)
                    }
                    withCStringArray(available) { avail in
                        items.withUnsafeBufferPointer { itemsBuf in
                            var complete = ghostty_clipboard_complete_s(
                                contents: itemsBuf.baseAddress, contents_len: itemsBuf.count,
                                available: avail.baseAddress, available_len: avail.count,
                                confirmed: true, remember: remember)
                            ghostty_surface_complete_clipboard_request(surface, &complete, state)
                        }
                    }
                }
            }
        }
    }
}

func ghosttyWriteClipboard(
    _ userdata: UnsafeMutableRawPointer?, _ clipboard: ghostty_clipboard_e,
    _ content: UnsafePointer<ghostty_clipboard_content_s>, _ count: Int, _ confirmed: Bool
) {
    guard clipboard == GHOSTTY_CLIPBOARD_STANDARD else { return }
    guard count > 0 else { return }
    // Contents are length-delimited and not necessarily NUL-terminated.
    func text(_ c: ghostty_clipboard_content_s) -> String? {
        String(decoding: UnsafeRawBufferPointer(start: c.data, count: c.len), as: UTF8.self)
    }
    let entries = (0..<count).map { content[$0] }
    let plain = entries.first { String(cString: $0.mime) == "text/plain" }
    guard let str = text(plain ?? entries[0]) else { return }
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(str, forType: .string)
}

extension NSPasteboard {
    fileprivate var ghosttyStringContents: String? {
        if let urls = readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            return urls.map { url in
                url.isFileURL ? RemoteExplorer.shellEscPath(url.path) : url.absoluteString
            }.joined(separator: " ")
        }
        return string(forType: .string)
    }
}

func ghosttyCloseSurface(_ userdata: UnsafeMutableRawPointer?, _ processAlive: Bool) {
    DispatchQueue.main.async {
        NotificationCenter.default.post(
            name: .ghosttyChildExited,
            object: nil,
            userInfo: ["processAlive": processAlive]
        )
    }
}
