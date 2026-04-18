import SwiftUI

// MARK: - Plugins Management

struct PluginSettingsView: View {
    /// Set by MainWindowController before showing settings.
    static var registeredManifests: [PluginManifest] = []

    @ObservedObject private var observer = SettingsObserver(topics: [.theme, .plugins])
    @State private var installError: String? = nil

    var body: some View {
        let _ = observer.revision
        let t = Tokens.current
        let manifests = Self.registeredManifests

        SettingsPage(title: "Plugins") {
            Text("Built-in plugins provide core functionality. External plugins are loaded from ~/.boo/plugins/")
                .font(.system(size: 11))
                .foregroundColor(t.muted)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(manifests, id: \.id) { manifest in
                    PluginRow(manifest: manifest)
                }
            }

            HStack {
                if let err = installError {
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundColor(.red)
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
                        installError =
                            "A plugin with ID '\(newManifest.id)' is already installed."
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

/// Dedicated settings page for a single plugin, shown when selected in the settings sidebar.
struct PluginDetailSettingsView: View {
    let manifest: PluginManifest
    @ObservedObject private var observer = SettingsObserver(topics: [.theme, .plugins])

    private var filteredSettings: [PluginManifest.SettingManifest] {
        guard let settings = manifest.settings else { return [] }
        if manifest.capabilities?.statusBarSegment == true {
            return settings.filter { $0.type != .bool }
        }
        return settings
    }

    /// Settings bucketed by group, preserving declaration order within each group.
    /// Ungrouped (nil group) settings use title `""`.
    private var groupedSettings: [(title: String, settings: [PluginManifest.SettingManifest])] {
        let grouped = Dictionary(grouping: filteredSettings) { $0.group ?? "" }
        // Preserve declaration order of groups by scanning filteredSettings for first appearance.
        var seen = Set<String>()
        let order = filteredSettings.compactMap { s -> String? in
            let key = s.group ?? ""
            return seen.insert(key).inserted ? key : nil
        }
        return order.map { (title: $0, settings: grouped[$0]!) }
    }

    var body: some View {
        let _ = observer.revision

        SettingsPage(title: manifest.name) {
            if filteredSettings.isEmpty {
                Text("No configurable settings for this plugin.")
                    .font(.system(size: 12))
                    .foregroundColor(Tokens.current.muted)
            } else {
                ForEach(groupedSettings, id: \.title) { group in
                    Section(title: group.title.isEmpty ? "Settings" : group.title, divided: true) {
                        ForEach(Array(group.settings.enumerated()), id: \.element.key) { idx, setting in
                            if idx > 0 { SettingsRowDivider() }
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

    /// Settings shown in plugin settings — excludes bool settings for plugins
    /// with statusBarSegment (those appear in Status Bar settings instead).
    private var filteredSettings: [PluginManifest.SettingManifest] {
        guard let settings = manifest.settings else { return [] }
        if manifest.capabilities?.statusBarSegment == true {
            return settings.filter { $0.type != .bool }
        }
        return settings
    }

    var body: some View {
        let _ = observer.revision
        let t = Tokens.current

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: manifest.icon)
                    .font(.system(size: 14))
                    .foregroundColor(isEnabled ? t.text : t.muted)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(manifest.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(isEnabled ? t.text : t.muted)
                        Text(manifest.isExternal ? "External" : "Built-in")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(t.muted)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(t.muted.opacity(0.15))
                            .cornerRadius(3)
                    }
                    Text(manifest.description ?? "")
                        .font(.system(size: 10))
                        .foregroundColor(t.muted)
                }
                Spacer()

                if manifest.isExternal {
                    Button(action: removePlugin) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .help("Remove plugin")
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
                    .foregroundColor(.red)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            }
        }
        .accessibilityLabel("\(manifest.name), \(isEnabled ? "enabled" : "disabled"), \(manifest.description ?? "")")
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
            boolControl.padding(.horizontal, 12).padding(.vertical, 8)
        case .double:
            doubleControl.padding(.horizontal, 12).padding(.vertical, 8)
        case .string:
            stringControl.padding(.horizontal, 12).padding(.vertical, 8)
        case .int:
            EmptyView()
        }
    }

    private var boolControl: some View {
        let value = AppSettings.shared.pluginBool(
            pluginID, setting.key, default: setting.defaultValue?.value as? Bool ?? false)
        return ToggleRow(
            label: setting.label,
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
        return HStack {
            Text(setting.label)
                .font(.system(size: 12))
                .foregroundColor(Tokens.current.text)
            Spacer()
            Slider(
                value: Binding(
                    get: { value },
                    set: { AppSettings.shared.setPluginSetting(pluginID, setting.key, $0) }
                ), in: lo...hi, step: step
            )
            Text(step < 1 ? String(format: "%.1f", value) : "\(Int(value))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Tokens.current.text)
                .frame(width: 32)
        }
        .frame(width: 200)
    }

    private var stringControl: some View {
        let value = AppSettings.shared.pluginString(
            pluginID, setting.key, default: setting.defaultValue?.value as? String ?? "")
        return Group {
            if setting.options == "markdownOpenMode" {
                markdownOpenModeControl
            } else if setting.options == "imageOpenMode" {
                imageOpenModeControl
            } else if setting.options == "textOpenMode" {
                textOpenModeControl
            } else if setting.options == "fontPicker:system" {
                HStack {
                    Text(setting.label)
                        .font(.system(size: 12))
                        .foregroundColor(Tokens.current.text)
                    Spacer()
                    fontPicker(value: value, fonts: AppSettings.availableSystemFonts)
                }
            } else if setting.options == "fontPicker:mono" {
                HStack {
                    Text(setting.label)
                        .font(.system(size: 12))
                        .foregroundColor(Tokens.current.text)
                    Spacer()
                    fontPicker(value: value, fonts: AppSettings.availableMonospaceFonts)
                }
            } else if setting.options == "dockerSocket" {
                dockerSocketControl(value: value)
            } else if setting.options == "editorFilePatterns" {
                editorFilePatternsControl(value: value)
            } else if setting.options == "gitDiffTool" {
                gitDiffToolControl(value: value)
            } else {
                HStack {
                    Text(setting.label)
                        .font(.system(size: 12))
                        .foregroundColor(Tokens.current.text)
                    Spacer()
                    TextField(
                        "",
                        text: Binding(
                            get: { value },
                            set: { AppSettings.shared.setPluginSetting(pluginID, setting.key, $0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                }
            }
        }
    }

    private var markdownOpenModeControl: some View {
        let t = Tokens.current
        return VStack(alignment: .leading, spacing: 6) {
            Text(setting.label)
                .font(.system(size: 12))
                .foregroundColor(t.text)
            Picker(
                "",
                selection: Binding(
                    get: { AppSettings.shared.markdownOpenMode.normalized },
                    set: { AppSettings.shared.markdownOpenMode = $0 }
                )
            ) {
                ForEach(MarkdownOpenMode.visibleCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    private var imageOpenModeControl: some View {
        let t = Tokens.current
        let current =
            (ImageOpenMode(
                rawValue: AppSettings.shared.pluginString(pluginID, setting.key, default: "imageViewer")
            ) ?? .imageViewer).normalized
        return VStack(alignment: .leading, spacing: 6) {
            Text(setting.label)
                .font(.system(size: 12))
                .foregroundColor(t.text)
            Picker(
                "",
                selection: Binding(
                    get: { current },
                    set: { AppSettings.shared.setPluginSetting(pluginID, setting.key, $0.rawValue) }
                )
            ) {
                ForEach(ImageOpenMode.visibleCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    private var textOpenModeControl: some View {
        let t = Tokens.current
        let current =
            (TextOpenMode(
                rawValue: AppSettings.shared.pluginString(pluginID, setting.key, default: "editor")
            ) ?? .editor).normalized
        return VStack(alignment: .leading, spacing: 6) {
            Text(setting.label)
                .font(.system(size: 12))
                .foregroundColor(t.text)
            Picker(
                "",
                selection: Binding(
                    get: { current },
                    set: { AppSettings.shared.setPluginSetting(pluginID, setting.key, $0.rawValue) }
                )
            ) {
                ForEach(TextOpenMode.visibleCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    private func dockerSocketControl(value: String) -> some View {
        let t = Tokens.current
        let detected = DockerService.shared.socketPath
        return VStack(alignment: .leading, spacing: 4) {
            Text(setting.label)
                .font(.system(size: 12))
                .foregroundColor(t.text)
            TextField(
                detected ?? "/var/run/docker.sock",
                text: Binding(
                    get: { value },
                    set: { AppSettings.shared.setPluginSetting(pluginID, setting.key, $0) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11, design: .monospaced))
            if let path = detected {
                Text("Leave empty to auto-detect. Currently using: \(path)")
                    .font(.system(size: 11))
                    .foregroundColor(t.muted)
            } else {
                Text("Leave empty to auto-detect.")
                    .font(.system(size: 11))
                    .foregroundColor(t.muted)
            }
        }
    }

    private func gitDiffToolControl(value: String) -> some View {
        let t = Tokens.current
        return VStack(alignment: .leading, spacing: 4) {
            Text(setting.label)
                .font(.system(size: 12))
                .foregroundColor(t.text)
            TextField(
                "e.g. code --diff {file}",
                text: Binding(
                    get: { value },
                    set: { AppSettings.shared.setPluginSetting(pluginID, setting.key, $0) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11, design: .monospaced))
            Text("Leave empty to use \u{2018}git diff\u{2019} in the terminal. Use {file} for the full file path.")
                .font(.system(size: 11))
                .foregroundColor(t.muted)
        }
    }

    private func editorFilePatternsControl(value: String) -> some View {
        let t = Tokens.current
        return VStack(alignment: .leading, spacing: 4) {
            Text(setting.label)
                .font(.system(size: 12))
                .foregroundColor(t.text)
            TextField(
                ContentType.builtInEditorFilePatterns,
                text: Binding(
                    get: { value },
                    set: { AppSettings.shared.setPluginSetting(pluginID, setting.key, $0) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11, design: .monospaced))
            Text(
                "Comma-separated patterns. Examples: swift, .gitignore, *.{ts,tsx}, .env*. Other files open with the default app."
            )
            .font(.system(size: 11))
            .foregroundColor(t.muted)
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
        .frame(width: 150)
    }
}
