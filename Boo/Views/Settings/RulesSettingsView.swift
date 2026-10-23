import SwiftUI

struct RulesSettingsView: View {
    @Environment(\.tokens) private var tokens
    @ObservedObject private var store = NotificationObserver([.rulesChanged])
    @State private var text = RulesStore.shared.text()
    @State private var savedText = RulesStore.shared.text()
    @State private var saveError: String?
    @State private var pattern = ""
    @State private var sample = ""

    var body: some View {
        let _ = store.revision
        let t = tokens
        let rules = RulesStore.shared

        SettingsPage(title: "Rules") {
            DescriptionLabel(
                text:
                    "Rules in ~/.boo/rules.json switch profiles by context (host, cwd, container, kubeContext, "
                    + "process) and fire actions on terminal output (notify, markTab, run, sendText, openLink). "
                    + "Output regex captures are available as $0…$9 and BOO_MATCH_0…9.")

            if !rules.problems.isEmpty {
                ProblemBanner(problems: rules.problems)
            }

            if !rules.suspended.isEmpty {
                Section(title: "Suspended") {
                    ForEach(rules.suspended.sorted(), id: \.self) { id in
                        HStack {
                            Text(id).font(.system(size: 12, design: .monospaced))
                            Text("fired too often")
                                .font(.system(size: 11))
                                .foregroundStyle(t.muted)
                            Spacer()
                            Button("Resume") { rules.resume(id) }
                                .buttonStyle(.themed)
                        }
                    }
                }
            }

            Section(title: "rules.json") {
                TextEditor(text: $text)
                    .font(.system(size: 12, design: .monospaced))
                    .autocorrectionDisabled()
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 220)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(t.subtleFill))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(t.separator, lineWidth: 0.5))
                if let saveError {
                    Text(saveError)
                        .font(.system(size: 11))
                        .foregroundStyle(t.error)
                }
                HStack {
                    Text("\(rules.all.rules.count) rules loaded")
                        .font(.system(size: 11))
                        .foregroundStyle(t.muted)
                    Spacer()
                    Button("Open in Editor") { NSWorkspace.shared.open(URL(fileURLWithPath: rules.path)) }
                    Button("Revert") {
                        text = rules.text()
                        savedText = text
                        saveError = nil
                    }
                    .disabled(text == savedText)
                    Button("Save") { save() }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(text == savedText && FileManager.default.fileExists(atPath: rules.path))
                }
                .buttonStyle(.themed)
            }

            Section(title: "Regex Tester") {
                SettingRow(label: "Pattern") {
                    SettingTextField(placeholder: #"(\d+) tests? failed"#, text: $pattern, monospaced: true)
                }
                SettingRow(label: "Sample", alignment: .top) {
                    TextEditor(text: $sample)
                        .font(.system(size: 12, design: .monospaced))
                        .autocorrectionDisabled()
                        .scrollContentBackground(.hidden)
                        .frame(height: 60)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(t.subtleFill))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(t.separator, lineWidth: 0.5))
                }
                testerResult(t)
            }

            Section(title: "Confirmations") {
                SettingRow(
                    label: "sendText",
                    help: "Each sendText rule asks once before it types into a terminal. Reset to be asked again."
                ) {
                    Button("Reset Approvals") { RuleEngine.resetConfirmations() }
                        .buttonStyle(.themed)
                }
            }
        }
        .foregroundStyle(t.text)
        .onChange(of: store.revision) { _, _ in
            // The file changed on disk: follow it unless there are unsaved edits.
            guard text == savedText else { return }
            text = rules.text()
            savedText = text
        }
    }

    @ViewBuilder
    private func testerResult(_ t: Tokens) -> some View {
        if pattern.isEmpty {
            EmptyView()
        } else if let regex = try? NSRegularExpression(pattern: pattern) {
            let lines = sample.split(whereSeparator: \.isNewline).map(String.init)
            let results = lines.compactMap { line -> (String, [String])? in
                let ns = line as NSString
                guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
                    return nil
                }
                let caps = (0..<m.numberOfRanges).map { i -> String in
                    let r = m.range(at: i)
                    return r.location == NSNotFound ? "" : ns.substring(with: r)
                }
                return (line, caps)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(results.isEmpty ? "No line matches." : "\(results.count) of \(lines.count) lines match")
                    .font(.system(size: 11))
                    .foregroundStyle(results.isEmpty ? t.muted : t.success)
                ForEach(Array(results.prefix(20).enumerated()), id: \.offset) { _, r in
                    Text(
                        r.1.enumerated().map { "$\($0.offset)=\($0.element)" }.prefix(10).joined(separator: "  ")
                    )
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .textSelection(.enabled)
                }
            }
        } else {
            Text("Not a valid regular expression.")
                .font(.system(size: 11))
                .foregroundStyle(t.error)
        }
    }

    private func save() {
        do {
            try RulesStore.shared.save(text: text)
            savedText = text
            saveError = nil
        } catch let error as RuleSet.ParseError {
            saveError = error.message
        } catch {
            saveError = error.localizedDescription
        }
    }
}
