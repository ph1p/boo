import AppKit
import SwiftUI

// MARK: - Shortcuts

struct ShortcutsSettingsView: View {
    @Environment(\.tokens) private var tokens
    @ObservedObject private var observer = SettingsObserver(topics: [.theme, .shortcuts])
    @State private var searchText: String = ""
    /// Bumped after the menu is rebuilt with new overrides.
    @State private var refresh = 0
    @State private var recordingID: String?
    @State private var message: String?
    @State private var monitor: Any?

    /// Generated from the live main menu, so it cannot drift from it.
    private var filteredGroups: [ActionRegistry.ShortcutGroup] {
        let groups = ActionRegistry.shortcutGroups(includeUnbound: true)
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return groups }
        return groups.compactMap { group in
            let matchingItems = group.entries.filter {
                $0.title.lowercased().contains(q) || $0.shortcut.lowercased().contains(q)
            }
            return matchingItems.isEmpty
                ? nil : ActionRegistry.ShortcutGroup(title: group.title, entries: matchingItems)
        }
    }

    var body: some View {
        let _ = observer.revision
        let _ = refresh
        let t = tokens
        // Once per render: each walks the whole menu or bridges the defaults dictionary.
        let groups = filteredGroups
        let overrides = AppSettings.shared.shortcutOverrides

        SettingsPage(title: "Keyboard Shortcuts") {
            QuickTerminalSettingsSection()

            SettingTextField(
                placeholder: "Filter shortcuts",
                text: $searchText,
                icon: "magnifyingglass",
                trailingClear: true
            )

            Text(
                "Click a shortcut to change it, then press the new keys. Delete removes it, Esc cancels."
            )
            .font(.system(size: 11))
            .foregroundStyle(t.muted)

            if let message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(t.accent)
            }

            if groups.isEmpty {
                Text("No shortcuts matching \"\(searchText)\"")
                    .font(.system(size: 12))
                    .foregroundStyle(t.muted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 24)
            } else {
                ForEach(groups, id: \.title) { group in
                    Section(title: group.title) {
                        ForEach(Array(group.entries.enumerated()), id: \.offset) { _, item in
                            shortcutRow(item, overridden: item.actionID.map { overrides[$0] != nil } ?? false, t: t)
                        }
                    }
                }
            }
        }
        .onDisappear { stopRecording() }
    }

    private func shortcutRow(_ item: ActionRegistry.ShortcutEntry, overridden: Bool, t: Tokens) -> some View {
        HStack {
            Text(item.title)
                .font(.system(size: 12))
                .foregroundStyle(t.text)
            Spacer()
            if let id = item.actionID {
                if overridden {
                    Button {
                        setOverride(nil, for: id)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 10))
                            .foregroundStyle(t.muted)
                    }
                    .buttonStyle(.plain)
                    .help("Reset to the default shortcut")
                }
                Button {
                    recordingID == id ? stopRecording() : startRecording(id)
                } label: {
                    if recordingID == id {
                        ShortcutPill(text: "Type shortcut…")
                    } else if item.shortcut.isEmpty {
                        Text("—")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(t.muted)
                            .padding(.horizontal, 6)
                    } else {
                        ShortcutPill(text: item.shortcut)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Shortcut for \(item.title): \(item.shortcut.isEmpty ? "none" : item.shortcut)")
                .accessibilityHint("Press to record a new shortcut")
            } else {
                ShortcutPill(text: item.shortcut)
            }
        }
    }

    // MARK: - Recording

    private func startRecording(_ id: String) {
        stopRecording()
        recordingID = id
        message = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handleRecorded(event) }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recordingID = nil
    }

    private func handleRecorded(_ event: NSEvent) {
        guard let id = recordingID else { return }
        let bare = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        if event.keyCode == 53, bare {  // Escape
            stopRecording()
            return
        }
        if event.keyCode == 51 || event.keyCode == 117, bare {  // Delete, Forward Delete
            stopRecording()
            setOverride("", for: id)
            return
        }
        guard let shortcut = ShortcutOverrides.shortcut(for: event) else {
            message = "Use ⌘, ⌃ or ⌥ with the key, or an F key."
            NSSound.beep()
            return
        }
        stopRecording()
        var overrides = AppSettings.shared.shortcutOverrides
        let actions = ActionRegistry.actions()
        let taken = ShortcutOverrides.conflicts(with: shortcut, excluding: id, in: actions)
        for other in taken { overrides[other.id] = "" }
        overrides[id] = ShortcutOverrides.spec(for: shortcut)
        if let action = actions.first(where: { $0.id == id }),
            ShortcutOverrides.defaultShortcut(for: action) == shortcut
        {
            overrides[id] = nil
        }
        message =
            taken.isEmpty
            ? nil
            : "\(shortcut.display) was removed from "
                + "\(taken.map { $0.path.dropFirst().joined(separator: " ") }.joined(separator: ", "))."
        save(overrides)
    }

    private func setOverride(_ spec: String?, for id: String) {
        var overrides = AppSettings.shared.shortcutOverrides
        overrides[id] = spec
        save(overrides)
    }

    private func save(_ overrides: [String: String]) {
        AppSettings.shared.shortcutOverrides = overrides
        // The menu is rebuilt by the settings broadcast; read it after that.
        DispatchQueue.main.async { refresh &+= 1 }
    }
}

// MARK: - Quick Terminal

struct QuickTerminalSettingsSection: View {
    @Environment(\.tokens) private var tokens
    @ObservedObject private var observer = SettingsObserver()
    @State private var hotkey = AppSettings.shared.quickTerminalHotkey

    var body: some View {
        let _ = observer.revision
        let t = tokens
        let settings = AppSettings.shared

        Section(title: "Quick Terminal") {
            ToggleRow(
                label: "Global hotkey",
                help: "Drops a terminal down from the top of the screen, from any app.",
                isOn: LayoutSettingsBindings.binding(\.quickTerminalEnabled)
            )
            SettingRow(
                label: "Shortcut",
                help: "Like opt+space, ctrl+`, cmd+shift+t or f12. Press Return to apply."
            ) {
                HStack(spacing: 8) {
                    SettingTextField(
                        placeholder: "opt+space", text: $hotkey, monospaced: true, width: 160,
                        onCommit: { settings.quickTerminalHotkey = hotkey.trimmingCharacters(in: .whitespaces) })
                    if let spec = HotKeySpec.parse(settings.quickTerminalHotkey) {
                        ShortcutPill(text: spec.display)
                    }
                }
            }
            if settings.quickTerminalEnabled, let problem = QuickTerminalController.shared.hotKeyProblem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: settings.theme.error))
            }
            SettingRow(label: "Height") {
                HStack(spacing: 8) {
                    Slider(value: LayoutSettingsBindings.binding(\.quickTerminalHeight), in: 0.2...0.9, step: 0.05)
                    Text("\(Int((settings.quickTerminalHeight * 100).rounded()))%")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(t.muted)
                        .frame(width: 36, alignment: .trailing)
                }
            }
            ToggleRow(
                label: "Hide when it loses focus",
                help: "Hiding keeps the shells running.",
                isOn: LayoutSettingsBindings.binding(\.quickTerminalHideOnResign)
            )
        }
    }
}
