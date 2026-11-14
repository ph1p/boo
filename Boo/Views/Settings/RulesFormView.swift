import SwiftUI

/// The form side of Settings → Rules: a list of the rules in `rules.json` and
/// an editor for one of them. Every change goes through `commit`, which
/// writes the whole document.
struct RulesFormView: View {
    @Environment(\.tokens) private var tokens
    let document: RulesDocument
    /// Saves the document; returns why it couldn't be saved, or nil.
    let commit: (RulesDocument) -> String?

    /// The entry being edited; nil with a `draft` is a new rule.
    @State private var editing: Int?
    @State private var original: [String: Any]?
    @State private var draft: RuleDraft?
    @State private var error: String?

    var body: some View {
        let t = tokens
        Section(title: "Rules") {
            if document.items.isEmpty {
                Text("No rules yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(t.muted)
            }
            ForEach(Array(document.items.indices), id: \.self) { index in
                row(index, t)
            }
            if let error, draft == nil {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(t.error)
            }
            HStack {
                Button("Add Rule") { add() }
                Spacer()
                Text("The first matching profile rule wins.")
                    .font(.system(size: 11))
                    .foregroundStyle(t.muted)
            }
            .buttonStyle(.themed)
        }

        if let draft {
            RuleEditor(
                draft: Binding(get: { draft }, set: { self.draft = $0 }),
                isNew: editing == nil,
                error: error,
                onSave: { save() },
                onCancel: { close() },
                onDelete: { delete() }
            )
            .id(editing ?? -1)
        }
    }

    @ViewBuilder
    private func row(_ index: Int, _ t: Tokens) -> some View {
        if let rule = document.rule(at: index) {
            HStack(spacing: 8) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { rule["enabled"] as? Bool ?? true },
                        set: { enabled in change { $0.setEnabled(enabled, at: index) } })
                )
                .labelsHidden()
                .toggleStyle(.themedCheckbox)
                .help("Enabled")
                Text(rule["id"] as? String ?? "rule-\(index + 1)")
                    .font(.system(size: 12, weight: editing == index ? .semibold : .regular, design: .monospaced))
                Text(RuleDraft.summary(of: rule))
                    .font(.system(size: 11))
                    .foregroundStyle(t.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                IconButton(systemName: "chevron.up", help: "Move up") { change { $0.move(at: index, by: -1) } }
                    .disabled(index == 0)
                IconButton(systemName: "chevron.down", help: "Move down") { change { $0.move(at: index, by: 1) } }
                    .disabled(index == document.items.count - 1)
                IconButton(systemName: "pencil", help: "Edit") { edit(index, rule) }
            }
            .contentShape(Rectangle())
            .onTapGesture { edit(index, rule) }
        } else {
            Text("Entry \(index + 1) is not a rule object. Edit it in the JSON view.")
                .font(.system(size: 11))
                .foregroundStyle(t.muted)
        }
    }

    /// A list change (enable, move). It closes the editor, whose index may no
    /// longer point at the same rule.
    private func change(_ body: (inout RulesDocument) -> Void) {
        var doc = document
        body(&doc)
        close()
        error = commit(doc)
    }

    private func add() {
        editing = nil
        original = nil
        error = nil
        draft = RuleDraft()
    }

    private func edit(_ index: Int, _ rule: [String: Any]) {
        editing = index
        original = rule
        error = nil
        draft = RuleDraft(rule)
    }

    private func close() {
        editing = nil
        original = nil
        draft = nil
        error = nil
    }

    /// Whether the entry under edit is still the one the editor opened. The
    /// file can change on disk while the editor is open.
    private var targetIsCurrent: Bool {
        guard let editing, let original else { return editing == nil }
        return document.rule(at: editing).map { ($0 as NSDictionary).isEqual(to: original) } ?? false
    }

    private func save() {
        guard let draft, !targetIsStale() else { return }
        // Nothing changed: leave the rule as written, so it keeps its approval.
        if let original, draft == RuleDraft(original) {
            close()
            return
        }
        if let problem = draft.problem {
            error = problem
            return
        }
        let rule = draft.applied(to: original ?? [:])
        if let id = rule["id"] as? String, document.ids(except: editing).contains(id) {
            error = "Another rule already has the id \"\(id)\"."
            return
        }
        if let problem = RuleDraft.parseProblem(in: rule) {
            error = problem
            return
        }
        var doc = document
        if let editing {
            doc.replace(at: editing, with: rule)
        } else {
            doc.append(rule)
        }
        if let failure = commit(doc) {
            error = failure
        } else {
            close()
        }
    }

    /// True, with the error shown, when the rule being edited changed on disk.
    private func targetIsStale() -> Bool {
        if targetIsCurrent { return false }
        error = "rules.json changed since you opened this rule. Cancel and open it again."
        return true
    }

    private func delete() {
        guard let editing, !targetIsStale() else { return }
        var doc = document
        doc.remove(at: editing)
        close()
        error = commit(doc)
    }
}

// MARK: - Editor

private struct RuleEditor: View {
    @Environment(\.tokens) private var tokens
    @Binding var draft: RuleDraft
    let isNew: Bool
    let error: String?
    let onSave: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    private static let placeholders: [String: String] = [
        "host": "*.prod.example.com", "cwd": "~/work/client", "container": "api-*", "kubeContext": "prod-*",
        "process": "vim", "workspace": "Client", "workspaceFolder": "~/work/**", "gitBranch": "release/*",
        "user": "root", "time": "09:00-18:00", "output": #"(\d+) tests? failed"#
    ]

    var body: some View {
        let t = tokens
        Section(title: isNew ? "New Rule" : "Edit Rule") {
            SettingRow(label: "ID", help: "Names the rule in notifications. Empty uses rule-N.") {
                SettingTextField(placeholder: "prod-ssh", text: $draft.id, monospaced: true, width: 260)
            }
            ToggleRow(label: "Enabled", isOn: $draft.enabled)

            caption("When: every field you fill in must match", t)
            ForEach(RuleCondition.orderedKeys, id: \.self) { key in
                SettingRow(label: key) {
                    SettingTextField(
                        placeholder: Self.placeholders[key] ?? "",
                        text: Binding(
                            get: { draft.conditions[key] ?? "" },
                            set: { draft.conditions[key] = $0.isEmpty ? nil : $0 }),
                        monospaced: true, width: 260)
                }
            }

            caption("Then", t)
            SettingRow(label: "Do") {
                ThemedSegmentedPicker(selection: $draft.kind, options: RuleDraft.Kind.allCases) { $0.title }
            }
            switch draft.kind {
            case .profile:
                SettingRow(label: "Profile", help: draft.hasOutput ? "An output rule can't use a profile." : nil) {
                    ThemedMenuPicker(selection: $draft.profile, options: ProfileStore.shared.names) {
                        $0.isEmpty ? "Choose…" : $0
                    }
                }
            case .actions:
                ForEach($draft.actions) { $action in
                    actionRow($action, t)
                }
                HStack {
                    Button("Add Action") { draft.actions.append(RuleDraft.Action(kind: .notify)) }
                    Spacer()
                }
                .buttonStyle(.themed)
            }

            if draft.hasOutput {
                caption("Output rules", t)
                SettingRow(label: "Cooldown", help: "Seconds before the rule can fire again. Empty uses 5.") {
                    SettingTextField(placeholder: "5", text: $draft.cooldown, monospaced: true, width: 80)
                }
                ToggleRow(
                    label: "Full-screen programs", help: "Also match output of vim, less, htop and the like.",
                    isOn: $draft.altScreen)
            }

            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(t.error)
            }
            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) { onDelete() }
                }
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave() }
                    .buttonStyle(.themedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .buttonStyle(.themed)
        }
    }

    private func caption(_ text: String, _ t: Tokens) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(t.muted)
    }

    @ViewBuilder
    private func actionRow(_ action: Binding<RuleDraft.Action>, _ t: Tokens) -> some View {
        HStack(spacing: 8) {
            if let kind = action.wrappedValue.kind {
                ThemedMenuPicker(
                    selection: Binding(get: { kind }, set: { action.wrappedValue.kind = $0 }),
                    options: RuleDraft.Action.Kind.allCases
                ) { $0.rawValue }
                switch kind {
                case .notify:
                    SettingTextField(placeholder: "Title (rule id)", text: action.title, width: 130)
                    SettingTextField(placeholder: "Body (matched line)", text: action.text)
                case .markTab:
                    Spacer()
                case .run:
                    SettingTextField(placeholder: "make test", text: action.text, monospaced: true)
                case .sendText:
                    SettingTextField(placeholder: "Text to type", text: action.text, monospaced: true)
                case .openLink:
                    SettingTextField(placeholder: "https://example.com/$1", text: action.text, monospaced: true)
                }
            } else {
                Text("Custom action. Edit it in the JSON view.")
                    .font(.system(size: 11))
                    .foregroundStyle(t.muted)
                Spacer()
            }
            IconButton(systemName: "trash", help: "Remove action") {
                draft.actions.removeAll { $0.id == action.wrappedValue.id }
            }
        }
    }
}
