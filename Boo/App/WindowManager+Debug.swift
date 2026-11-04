#if DEBUG
    import AppKit

    /// Dev builds only: socket commands that let a script see and drive the UI
    /// without screen-recording or accessibility permission.
    ///
    /// - `debug_snapshot {path, sidebar_tab?, dialog?, settings_plugin?}`: draws the first window
    ///   (or, with `dialog: true`, its open sheet or modal alert; with `settings_plugin`, the
    ///   Settings window open on that plugin's page) to a PNG.
    /// - `debug_crew_action {action, handle?|name?, text?}`: what a crew sidebar button does
    ///   (`show`, `message`, `resume`, `review`, `merge`, `discard`, `allow`, `deny`, `new_task`).
    ///   `message` and `new_task` open their inline field, or send `text` right away.
    /// - `debug_dialog {button, text?}`: types `text` into the open sheet or alert and presses `button`.
    /// - `debug_close_workspace {id}`: closes a workspace without asking (ids from `get_workspaces`).
    /// - `debug_review_send {id, text}`: the review tab's "Send to Agent" with `text` as its note.
    /// - `debug_click {x, y, count?}`: a left click at a point of the `debug_snapshot` image (points,
    ///   top-left origin), sent through the window like a real one, so hit-testing runs.
    ///   `count: 2` double-clicks (two clicks, the second with click count 2).
    /// - `debug_key {key, chars?}`: a key press (key code; `chars` for text keys) sent to the
    ///   first window's key view, e.g. 125 ↓, 126 ↑, 36 Return, 49 Space, 51 Delete, 53 Esc.
    extension WindowManager {
        func handleDebugCommand(cmd: String, json: [String: Any], reply: @escaping ([String: Any]) -> Void) -> Bool {
            switch cmd {
            case "debug_snapshot":
                guard let path = json["path"] as? String else { return false }
                let controller = controllers.first
                if let tab = json["sidebar_tab"] as? String, let ctx = controller?.pluginRegistry.lastContext {
                    controller?.activatePluginTab(SidebarTabID(tab), context: ctx)
                    controller?.window?.contentView?.layoutSubtreeIfNeeded()
                }
                var window = json["dialog"] as? Bool == true ? openDialog() : controller?.window
                if let plugin = json["settings_plugin"] as? String {
                    SettingsWindowController.shared.showSettings(tab: .pluginSettings(pluginID: plugin))
                    window = SettingsWindowController.shared.window
                    window?.contentView?.layoutSubtreeIfNeeded()
                }
                guard let view = window?.contentView?.superview ?? window?.contentView,
                    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                else {
                    reply(["ok": false, "error": "no window"])
                    return true
                }
                view.cacheDisplay(in: view.bounds, to: rep)
                let png = rep.representation(using: .png, properties: [:])
                reply(["ok": (try? png?.write(to: URL(fileURLWithPath: path))) != nil, "path": path])
            case "debug_crew_action":
                guard let action = (json["action"] as? String).flatMap(AgentsPlugin.CrewAction.init) else {
                    reply(["ok": false, "error": "unknown action"])
                    return true
                }
                // Stopped task rows have no handle; they are picked by name.
                let handle = json["handle"] as? String ?? json["name"] as? String
                let row = AgentsPlugin.allCrewRows().first { $0.handle == handle || ($0.isStopped && $0.name == handle) }
                guard action == .newTask || row != nil else {
                    reply(["ok": false, "error": "no agent \(handle ?? "")"])
                    return true
                }
                reply(["ok": true])
                // A run-loop block, not GCD: merge asks in a modal alert, and one
                // inside a main-queue block would starve the next socket command.
                let text = json["text"] as? String
                RunLoop.main.perform(inModes: [.common]) { AgentsPlugin.perform(action, on: row, text: text) }
            case "debug_close_workspace":
                // No confirmation, like a confirmed close: tidies up after a test run.
                let id = (json["id"] as? String).flatMap(UUID.init(uuidString:))
                guard let controller = controllers.first(where: { $0.appState.workspaces.contains { $0.id == id } }),
                    let index = controller.appState.workspaces.firstIndex(where: { $0.id == id })
                else {
                    reply(["ok": false, "error": "no workspace"])
                    return true
                }
                controller.forceCloseWorkspace(at: index)
                reply(["ok": true])
            case "debug_review_send":
                guard let id = (json["id"] as? String).flatMap(UUID.init(uuidString:)),
                    let folder = controllers.lazy.flatMap(\.appState.workspaces).first(where: { $0.id == id })?.folderPath
                else {
                    reply(["ok": false, "error": "no workspace"])
                    return true
                }
                let model = AgentReviewModel(workspaceID: id, folder: folder)
                model.note.text = json["text"] as? String ?? ""
                model.send()
                reply(["ok": model.status == nil, "status": model.status ?? ""])
            case "debug_click":
                guard let window = controllers.first?.window, let x = json["x"] as? Double, let y = json["y"] as? Double
                else {
                    reply(["ok": false, "error": "no window or point"])
                    return true
                }
                let point = NSPoint(x: x, y: window.frame.height - y)
                let count = max(1, json["count"] as? Int ?? 1)
                reply(["ok": true])
                RunLoop.main.perform(inModes: [.common]) {
                    let clicks = (1...count).flatMap { n in [(NSEvent.EventType.leftMouseDown, n), (.leftMouseUp, n)] }
                    for (type, clickCount) in [(NSEvent.EventType.mouseMoved, 1)] + clicks {
                        guard let event = NSEvent.mouseEvent(
                            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount,
                            pressure: type == .leftMouseDown ? 1 : 0)
                        else { continue }
                        window.sendEvent(event)
                    }
                }
            case "debug_key":
                guard let window = controllers.first?.window, let code = json["key"] as? Int else {
                    reply(["ok": false, "error": "no window or key"])
                    return true
                }
                let chars = json["chars"] as? String ?? ""
                reply(["ok": true])
                RunLoop.main.perform(inModes: [.common]) {
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        guard let event = NSEvent.keyEvent(
                            with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, characters: chars,
                            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code))
                        else { continue }
                        window.sendEvent(event)
                    }
                }
            case "debug_dialog":
                guard let dialog = openDialog(), let title = json["button"] as? String else {
                    reply(["ok": false, "error": "no dialog"])
                    return true
                }
                let views = Self.subviews(of: dialog.contentView)
                if let text = json["text"] as? String,
                    let field = views.compactMap({ $0 as? NSTextField }).first(where: \.isEditable)
                {
                    field.stringValue = text
                }
                guard let button = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else {
                    reply(["ok": false, "error": "no button \(title)"])
                    return true
                }
                reply(["ok": true])
                RunLoop.main.perform(inModes: [.common]) { button.performClick(nil) }
            default:
                return false
            }
            return true
        }

        private func openDialog() -> NSWindow? {
            NSApp.modalWindow ?? controllers.lazy.compactMap { $0.window?.attachedSheet }.first
        }

        private static func subviews(of view: NSView?) -> [NSView] {
            guard let view else { return [] }
            return [view] + view.subviews.flatMap { subviews(of: $0) }
        }
    }
#endif
