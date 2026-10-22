import SwiftUI
import UniformTypeIdentifiers

/// Re-renders a view when a file-backed store posts its change notification.
@MainActor
final class NotificationObserver: ObservableObject {
    @Published var revision = 0
    nonisolated(unsafe) private var tokens: [Any] = []

    init(_ names: [Notification.Name]) {
        tokens = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.revision += 1 }
            }
        }
    }

    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}

// MARK: - Shader Picker

/// Off, a bundled preset, or a GLSL file picked from disk.
struct ShaderPicker: View {
    @Binding var value: String

    private var isCustom: Bool { !value.isEmpty && !ShaderLibrary.presets.contains(value) }

    var body: some View {
        HStack(spacing: 6) {
            Picker("", selection: $value) {
                Text("Off").tag("")
                ForEach(ShaderLibrary.presets, id: \.self) { Text(ShaderLibrary.displayName($0)).tag($0) }
                if isCustom {
                    Divider()
                    Text((value as NSString).lastPathComponent).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 180, alignment: .leading)
            Button("Choose File…") { choose() }
                .controlSize(.small)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "glsl") ?? .plainText, .plainText]
        panel.allowsOtherFileTypes = true
        panel.message = "Choose a Shadertoy-style GLSL file (mainImage, iChannel0)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        value = (url.path as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: - Profiles

struct ProfilesSettingsView: View {
    @Environment(\.tokens) private var tokens
    @ObservedObject private var store = NotificationObserver([.profilesChanged])
    @ObservedObject private var observer = SettingsObserver(topics: [.profiles, .theme])
    @State private var selected: String?
    @State private var draft: Profile?
    @State private var saveError: String?

    private var profiles: [Profile] { ProfileStore.shared.profiles }

    var body: some View {
        let _ = store.revision
        let _ = observer.revision
        let t = tokens

        SettingsPage(title: "Profiles") {
            DescriptionLabel(
                text:
                    "A profile overrides parts of the global settings for one tab. Rules in Settings → Rules switch "
                    + "profiles by host, folder, container or Kubernetes context; the tab menu and the palette "
                    + "(:profile) switch by hand.")

            if !ProfileStore.shared.problems.isEmpty {
                ProblemBanner(problems: ProfileStore.shared.problems)
            }

            Section(title: "Default") {
                SettingRow(label: "New tabs use", help: "Used when no rule matches.") {
                    Picker(
                        "",
                        selection: Binding(
                            get: { AppSettings.shared.defaultProfile ?? "" },
                            set: { AppSettings.shared.defaultProfile = $0.isEmpty ? nil : $0 })
                    ) {
                        Text("None").tag("")
                        ForEach(profiles, id: \.name) { Text($0.name).tag($0.name) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 200, alignment: .leading)
                }
            }

            Section(title: "Profiles") {
                if profiles.isEmpty {
                    Text("No profiles yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(t.muted)
                }
                ForEach(profiles, id: \.name) { profile in
                    profileRow(profile, t)
                }
                HStack {
                    Button("Add Profile") { add() }
                        .controlSize(.small)
                    Spacer()
                    Button("Open profiles.json") { openFile() }
                        .controlSize(.small)
                }
            }

            if let draft {
                ProfileEditor(
                    profile: Binding(get: { draft }, set: { self.draft = $0 }),
                    isNew: !profiles.contains { $0.name == selected },
                    error: saveError,
                    onSave: { save($0) },
                    onCancel: { close() },
                    onDelete: { delete() }
                )
                .id(selected ?? "")
            }
        }
        .foregroundStyle(t.text)
    }

    private func profileRow(_ profile: Profile, _ t: Tokens) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(
                    Color(
                        nsColor: ProfileStore.shared.accent(forProfile: profile.name)
                            ?? AppSettings.shared.theme.accentColor)
                )
                .frame(width: 8, height: 8)
            Text(profile.name)
                .font(.system(size: 12, weight: selected == profile.name ? .semibold : .regular))
            Text(Self.summary(of: profile))
                .font(.system(size: 11))
                .foregroundStyle(t.muted)
                .lineLimit(1)
            Spacer()
            if AppSettings.shared.defaultProfile == profile.name {
                Text("Default")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(t.muted)
            }
            IconButton(systemName: "pencil", help: "Edit") { edit(profile) }
        }
        .contentShape(Rectangle())
        .onTapGesture { edit(profile) }
    }

    static func summary(of p: Profile) -> String {
        var parts: [String] = []
        if let v = p.theme { parts.append(v) }
        if let v = p.fontFamily { parts.append(v) }
        if let v = p.fontSize { parts.append("\(Int(v)) pt") }
        if let v = p.shader { parts.append(v.isEmpty ? "no shader" : ShaderLibrary.displayName(v)) }
        if let v = p.shell { parts.append(v) }
        if let v = p.cwd { parts.append(v) }
        if let env = p.env, !env.isEmpty { parts.append("\(env.count) env") }
        if let v = p.linkTarget { parts.append(v.displayName) }
        return parts.joined(separator: " · ")
    }

    private func add() {
        var n = 1
        var name = "New Profile"
        while profiles.contains(where: { $0.name == name }) {
            n += 1
            name = "New Profile \(n)"
        }
        selected = nil
        saveError = nil
        draft = Profile(name: name)
    }

    private func edit(_ profile: Profile) {
        selected = profile.name
        saveError = nil
        draft = profile
    }

    private func close() {
        selected = nil
        draft = nil
        saveError = nil
    }

    private func save(_ profile: Profile) {
        var p = profile
        p.name = p.name.trimmingCharacters(in: .whitespaces)
        guard !p.name.isEmpty else {
            saveError = "A profile needs a name."
            return
        }
        var list = profiles
        if p.name != selected, list.contains(where: { $0.name == p.name }) {
            saveError = "A profile named \"\(p.name)\" already exists."
            return
        }
        if let selected, let i = list.firstIndex(where: { $0.name == selected }) {
            list[i] = p
        } else {
            list.append(p)
        }
        do {
            try ProfileStore.shared.save(list)
            // Keep the default pointing at a renamed profile.
            if let selected, selected != p.name, AppSettings.shared.defaultProfile == selected {
                AppSettings.shared.defaultProfile = p.name
            }
            close()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func delete() {
        guard let selected else { return close() }
        do {
            try ProfileStore.shared.save(profiles.filter { $0.name != selected })
            if AppSettings.shared.defaultProfile == selected { AppSettings.shared.defaultProfile = nil }
            close()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func openFile() {
        let path = ProfileStore.shared.path
        if !FileManager.default.fileExists(atPath: path) {
            try? ProfileStore.shared.save(profiles)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

// MARK: - Profile Editor

/// Every field has an "Inherit" switch: off leaves it nil so the global
/// setting applies.
private struct ProfileEditor: View {
    @Environment(\.tokens) private var tokens
    @Binding var profile: Profile
    let isNew: Bool
    let error: String?
    let onSave: (Profile) -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    @State private var envText = ""

    private let monoFonts = AppSettings.availableMonospaceFonts

    var body: some View {
        let t = tokens
        Section(title: isNew ? "New Profile" : "Edit Profile") {
            SettingRow(label: "Name") {
                SettingTextField(placeholder: "Production", text: $profile.name, width: 220)
            }
            SettingsRowDivider()

            field("Theme", value: $profile.theme, fallback: AppSettings.shared.themeName) { binding in
                Picker("", selection: binding) {
                    ForEach(AppSettings.shared.allThemes, id: \.name) { Text($0.name).tag($0.name) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 220, alignment: .leading)
            }
            field("Font", value: $profile.fontFamily, fallback: AppSettings.shared.fontName) { binding in
                FontChooser(selectedFont: binding, fonts: monoFonts)
                    .frame(maxWidth: 220, alignment: .leading)
            }
            field("Font size", value: $profile.fontSize, fallback: Double(AppSettings.shared.fontSize)) { binding in
                FontSizePicker(value: binding, range: 8...36)
                    .frame(maxWidth: 120, alignment: .leading)
            }
            field("Shader", value: $profile.shader, fallback: AppSettings.shared.terminalShader) { binding in
                ShaderPicker(value: binding)
            }
            field("Link target", value: $profile.linkTarget, fallback: AppSettings.shared.defaultLinkTarget) {
                binding in
                Picker("", selection: binding) {
                    ForEach(LinkTarget.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 200, alignment: .leading)
            }

            SettingsRowDivider()
            Text("New tabs only")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(t.muted)
            field("Shell", value: $profile.shell, fallback: "") { binding in
                SettingTextField(placeholder: "/bin/zsh", text: binding, monospaced: true, width: 220)
            }
            field("Directory", value: $profile.cwd, fallback: "") { binding in
                SettingTextField(placeholder: "~/work", text: binding, monospaced: true, width: 220)
            }
            SettingRow(label: "Environment", help: "One NAME=value per line.", alignment: .top) {
                TextEditor(text: $envText)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(height: 54)
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(t.chromeBg.opacity(0.4))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(t.border, lineWidth: 1)))
            }

            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(t.error)
            }
            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) { onDelete() }
                        .controlSize(.small)
                }
                Spacer()
                Button("Cancel") { onCancel() }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    var p = profile
                    p.env = Self.parseEnv(envText)
                    onSave(p)
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { envText = Self.formatEnv(profile.env) }
    }

    /// A row with an Inherit switch. Turning it off seeds the value with the
    /// global setting so the control starts from what the tab shows today.
    @ViewBuilder
    private func field<Value, Control: View>(
        _ label: String, value: Binding<Value?>, fallback: Value,
        @ViewBuilder control: @escaping (Binding<Value>) -> Control
    ) -> some View {
        let t = tokens
        let inherits = value.wrappedValue == nil
        SettingRow(label: label) {
            HStack(spacing: 8) {
                Toggle(
                    "Inherit",
                    isOn: Binding(
                        get: { value.wrappedValue == nil },
                        set: { value.wrappedValue = $0 ? nil : fallback })
                )
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .foregroundStyle(t.muted)
                if !inherits {
                    control(Binding(get: { value.wrappedValue ?? fallback }, set: { value.wrappedValue = $0 }))
                }
                Spacer(minLength: 0)
            }
        }
    }

    static func parseEnv(_ text: String) -> [String: String]? {
        var env: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            env[key] = String(trimmed[trimmed.index(after: eq)...])
        }
        return env.isEmpty ? nil : env
    }

    static func formatEnv(_ env: [String: String]?) -> String {
        (env ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }
}

// MARK: - Problem Banner

/// Why a config file (or some of its entries) couldn't be used.
struct ProblemBanner: View {
    @Environment(\.tokens) private var tokens
    let problems: [String]

    var body: some View {
        let t = tokens
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(t.warning)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(problems.enumerated()), id: \.offset) { _, p in
                    Text(p)
                        .font(.system(size: 11))
                        .foregroundStyle(t.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(t.warning.opacity(0.12)))
    }
}
