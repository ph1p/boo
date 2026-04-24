import SwiftUI

// MARK: - Plugins Management

struct PluginSettingsView: View {
    /// Set by MainWindowController before showing settings.
    nonisolated(unsafe) static var registeredManifests: [PluginManifest] = []

    @ObservedObject private var observer = SettingsObserver(topics: [.theme, .plugins])
    @State private var installError: String? = nil

    var body: some View {
        let _ = observer.revision
        let t = Tokens.current
        let manifests = Self.registeredManifests

        SettingsPage(title: "Plugins") {
            Text("Built-in plugins provide core functionality. External plugins are loaded from ~/.boo/plugins/")
                .font(.system(size: 11))
                .foregroundStyle(t.muted)

            Section(title: "Installed") {
                ForEach(manifests, id: \.id) { manifest in
                    PluginRow(manifest: manifest)
                }
            }

            HStack {
                if let err = installError {
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("Install Plugin…") {
                    installError = nil
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.prompt = "Install"
                    panel.message = "Choose a plugin folder containing plugin.json"
                    guard panel.runModal() == .OK, let src = panel.url else { return }
                    let manifestURL = src.appendingPathComponent("plugin.json")
                    guard let manifestData = try? Data(contentsOf: manifestURL),
                        let newManifest = try? PluginManifest.parse(from: manifestData)
                    else {
                        installError = "No valid plugin.json found in selected folder."
                        return
                    }
                    if Self.registeredManifests.contains(where: { $0.id == newManifest.id }) {
                        installError = "A plugin with ID '\(newManifest.id)' is already installed."
                        return
                    }
                    let pluginsDir = (BooPaths.configDir as NSString).appendingPathComponent("plugins")
                    let dest = URL(fileURLWithPath: pluginsDir).appendingPathComponent(src.lastPathComponent)
                    do {
                        try? FileManager.default.removeItem(at: dest)
                        try FileManager.default.copyItem(at: src, to: dest)
                    } catch {
                        installError = "Install failed: \(error.localizedDescription)"
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.top, 4)
        }
    }
}

// MARK: - Plugin Detail Settings

struct PluginDetailSettingsView: View {
    let manifest: PluginManifest
    @ObservedObject private var observer = SettingsObserver(topics: [.theme, .plugins])

    private var groupedSettings: [(title: String, settings: [PluginManifest.SettingManifest])] {
        let visible = manifest.visibleSettings
        var seen = Set<String>()
        let order = visible.compactMap { s -> String? in
            let key = s.group ?? ""
            return seen.insert(key).inserted ? key : nil
        }
        let grouped = Dictionary(grouping: visible) { $0.group ?? "" }
        return order.map { (title: $0, settings: grouped[$0]!) }
    }

    var body: some View {
        let _ = observer.revision

        SettingsPage(title: manifest.name) {
            if manifest.id == "agents" {
                AgentCenterSettingsView()
            } else if manifest.visibleSettings.isEmpty {
                Text("No configurable settings for this plugin.")
                    .font(.system(size: 12))
                    .foregroundStyle(Tokens.current.muted)
            } else {
                ForEach(groupedSettings, id: \.title) { group in
                    Section(title: group.title.isEmpty ? "Settings" : group.title) {
                        ForEach(group.settings, id: \.key) { setting in
                            PluginSettingControl(pluginID: manifest.id, setting: setting)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Plugin Row

private struct PluginRow: View {
    let manifest: PluginManifest

    @State private var isEnabled: Bool
    @State private var removeError: String? = nil
    @ObservedObject private var observer = SettingsObserver(topics: [.theme, .plugins])

    init(manifest: PluginManifest) {
        self.manifest = manifest
        self._isEnabled = State(initialValue: !AppSettings.shared.disabledPluginIDs.contains(manifest.id))
    }

    private func removePlugin() {
        guard let folder = manifest.folderName else { return }
        let pluginsDir = (BooPaths.configDir as NSString).appendingPathComponent("plugins")
        let folderPath = (pluginsDir as NSString).appendingPathComponent(folder)
        do {
            try FileManager.default.removeItem(atPath: folderPath)
        } catch {
            removeError = error.localizedDescription
        }
    }

    var body: some View {
        let _ = observer.revision
        let t = Tokens.current

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: manifest.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(isEnabled ? t.text : t.muted)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(manifest.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(isEnabled ? t.text : t.muted)
                        Text(manifest.isExternal ? "External" : "Built-in")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(t.muted)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(t.muted.opacity(0.15))
                            .cornerRadius(3)
                    }
                    Text(manifest.description ?? "")
                        .font(.system(size: 10))
                        .foregroundStyle(t.muted)
                }
                Spacer()

                if manifest.isExternal {
                    IconButton(
                        systemName: "trash",
                        tint: .red.opacity(0.8),
                        help: "Remove plugin",
                        action: removePlugin
                    )
                }

                Toggle("", isOn: $isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: isEnabled) { _, enabled in
                        var disabled = AppSettings.shared.disabledPluginIDs
                        if enabled {
                            disabled.removeAll { $0 == manifest.id }
                        } else {
                            disabled.append(manifest.id)
                        }
                        AppSettings.shared.disabledPluginIDs = disabled
                    }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)

            if let err = removeError {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            }
        }
        .accessibilityLabel("\(manifest.name), \(isEnabled ? "enabled" : "disabled"), \(manifest.description ?? "")")
        .onChange(of: observer.revision) { _, _ in
            isEnabled = !AppSettings.shared.disabledPluginIDs.contains(manifest.id)
        }
    }
}

// MARK: - Plugin Setting Control

private struct PluginSettingControl: View {
    let pluginID: String
    let setting: PluginManifest.SettingManifest
    @ObservedObject private var observer = SettingsObserver(topics: [.theme, .plugins])

    var body: some View {
        let _ = observer.revision
        switch setting.type {
        case .bool:
            boolControl
        case .double:
            doubleControl
        case .string:
            stringControl
        case .int:
            EmptyView()
        }
    }

    private var boolControl: some View {
        let value = AppSettings.shared.pluginBool(
            pluginID, setting.key, default: setting.defaultValue?.value as? Bool ?? false)
        return ToggleRow(
            label: setting.label,
            help: setting.description,
            isOn: Binding(
                get: { value },
                set: { AppSettings.shared.setPluginSetting(pluginID, setting.key, $0) }
            ))
    }

    private var doubleControl: some View {
        let value = AppSettings.shared.pluginDouble(
            pluginID, setting.key, default: setting.defaultValue?.value as? Double ?? 0)
        let lo = setting.min ?? 0
        let hi = setting.max ?? 100
        let step = setting.step ?? 1
        return SettingRow(label: setting.label, help: setting.description) {
            HStack(spacing: 8) {
                Slider(
                    value: Binding(
                        get: { value },
                        set: { AppSettings.shared.setPluginSetting(pluginID, setting.key, $0) }
                    ), in: lo...hi, step: step
                )
                Text(step < 1 ? String(format: "%.1f", value) : "\(Int(value))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Tokens.current.text)
                    .frame(width: 32, alignment: .trailing)
            }
            .frame(maxWidth: 260)
        }
    }

    private var stringControl: some View {
        let value = AppSettings.shared.pluginString(
            pluginID, setting.key, default: setting.defaultValue?.value as? String ?? "")
        return Group {
            if setting.options == "markdownOpenMode" {
                openModePicker(
                    cases: MarkdownOpenMode.visibleCases,
                    current: (MarkdownOpenMode(rawValue: AppSettings.shared.markdownOpenMode.rawValue) ?? .builtInEditor)
                        .normalized,
                    set: { AppSettings.shared.markdownOpenMode = $0 }
                )
            } else if setting.options == "imageOpenMode" {
                openModePicker(
                    cases: ImageOpenMode.visibleCases,
                    current: (ImageOpenMode(
                        rawValue: AppSettings.shared.pluginString(pluginID, setting.key, default: "imageViewer"))
                        ?? .imageViewer).normalized,
                    set: { AppSettings.shared.setPluginSetting(pluginID, setting.key, $0.rawValue) }
                )
            } else if setting.options == "textOpenMode" {
                openModePicker(
                    cases: TextOpenMode.visibleCases,
                    current: (TextOpenMode(
                        rawValue: AppSettings.shared.pluginString(pluginID, setting.key, default: "editor")) ?? .editor)
                        .normalized,
                    set: { AppSettings.shared.setPluginSetting(pluginID, setting.key, $0.rawValue) }
                )
            } else if setting.options == "fontPicker:system" {
                SettingRow(label: setting.label, help: setting.description) {
                    fontPicker(value: value, fonts: AppSettings.availableSystemFonts)
                }
            } else if setting.options == "fontPicker:mono" {
                SettingRow(label: setting.label, help: setting.description) {
                    fontPicker(value: value, fonts: AppSettings.availableMonospaceFonts)
                }
            } else {
                SettingRow(label: setting.label, help: stringHelp) {
                    SettingTextField(
                        placeholder: stringPlaceholder,
                        text: Binding(
                            get: { value },
                            set: { AppSettings.shared.setPluginSetting(pluginID, setting.key, $0) }
                        ),
                        monospaced: true
                    )
                }
            }
        }
    }

    private var stringPlaceholder: String {
        switch setting.options {
        case "dockerSocket": return DockerService.shared.socketPath ?? "/var/run/docker.sock"
        case "gitDiffTool": return "e.g. code --diff {file}"
        case "editorFilePatterns": return ContentType.builtInEditorFilePatterns
        default: return ""
        }
    }

    private var stringHelp: String? {
        if setting.options == "dockerSocket", let detected = DockerService.shared.socketPath {
            return "Leave empty to auto-detect. Currently using: \(detected)"
        }
        return setting.description
    }

    private func openModePicker<M: OpenModePickable>(
        cases: [M], current: M, set: @escaping @Sendable (M) -> Void
    ) -> some View {
        SettingRow(label: setting.label, help: setting.description) {
            Picker("", selection: Binding(get: { current }, set: set)) {
                ForEach(cases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 200, alignment: .leading)
        }
    }

    private func fontPicker(value: String, fonts: [String]) -> some View {
        let displayValue = value.isEmpty ? "System Default" : value
        return Picker(
            "",
            selection: Binding(
                get: { displayValue },
                set: { AppSettings.shared.setPluginSetting(pluginID, setting.key, $0 == "System Default" ? "" : $0) }
            )
        ) {
            ForEach(fonts, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
        .frame(maxWidth: 200, alignment: .leading)
    }
}
