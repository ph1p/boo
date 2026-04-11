import SwiftUI

// MARK: - Plugins

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

// MARK: - Plugin Row

private struct PluginRow: View {
    let manifest: PluginManifest

    @State private var isEnabled: Bool
    @State private var isExpanded: Bool = false
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

    private var hasCustomSettings: Bool {
        for s in filteredSettings {
            switch s.type {
            case .bool:
                let def = s.defaultValue?.value as? Bool ?? false
                if AppSettings.shared.pluginBool(manifest.id, s.key, default: def) != def { return true }
            case .double:
                let def = s.defaultValue?.value as? Double ?? 0
                if AppSettings.shared.pluginDouble(manifest.id, s.key, default: def) != def { return true }
            case .string:
                let def = s.defaultValue?.value as? String ?? ""
                if AppSettings.shared.pluginString(manifest.id, s.key, default: def) != def { return true }
            case .int:
                break
            }
        }
        return false
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

                if !filteredSettings.isEmpty {
                    Button(action: { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() } }) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(t.muted)
                            if hasCustomSettings && !isExpanded {
                                Circle()
                                    .fill(t.accent)
                                    .frame(width: 5, height: 5)
                                    .offset(x: 4, y: -3)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }

                Toggle("", isOn: $isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: isEnabled) { enabled in
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

            if isExpanded, !filteredSettings.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(filteredSettings, id: \.key) { setting in
                        PluginSettingControl(pluginID: manifest.id, setting: setting)
                    }
                }
                .padding(.leading, 48)
                .padding(.trailing, 8)
                .padding(.bottom, 8)
            }

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
            if setting.options == "fontPicker:system" {
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
            } else if setting.options == "editorExtensions" {
                editorExtensionsControl(value: value)
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

    private func editorExtensionsControl(value: String) -> some View {
        let t = Tokens.current
        return VStack(alignment: .leading, spacing: 4) {
            Text(setting.label)
                .font(.system(size: 12))
                .foregroundColor(t.text)
            TextField(
                LocalFileTreePlugin.defaultEditorExtensions,
                text: Binding(
                    get: { value },
                    set: { AppSettings.shared.setPluginSetting(pluginID, setting.key, $0) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11, design: .monospaced))
            Text("Comma-separated. Other file types open with the default app.")
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
