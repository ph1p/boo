import SwiftUI

struct BrowserSettingsView: View {
    @State private var homePage = AppSettings.shared.browserHomePage
    @State private var persistentWebsiteDataEnabled = AppSettings.shared.browserPersistentWebsiteDataEnabled
    @State private var historyEnabled = AppSettings.shared.browserHistoryEnabled
    @State private var historyLimit = AppSettings.shared.browserHistoryLimit
    @State private var linkOpenMode = AppSettings.shared.linkOpenMode
    @State private var showClearConfirm = false
    @State private var historyEntries: [BrowserHistoryEntry] = []
    @State private var searchText = ""
    @ObservedObject private var observer = SettingsObserver(topics: [.theme])

    private var filteredEntries: [BrowserHistoryEntry] {
        guard !searchText.isEmpty else { return historyEntries }
        return historyEntries.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.url.absoluteString.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        let _ = observer.revision
        let t = Tokens.current

        SettingsPage(title: "Browser") {
            // MARK: General
            Section(title: "General") {
                HStack(spacing: 8) {
                    Text("Home page")
                        .font(.system(size: 12))
                        .foregroundStyle(t.text)
                        .frame(width: 80, alignment: .leading)
                    TextField("https://google.com", text: $homePage)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(t.text)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(t.border, lineWidth: 1)
                        )
                        .onSubmit { save() }
                        .onChange(of: homePage) { _, _ in save() }
                }
                Text("Opened when creating a new browser tab.")
                    .font(.system(size: 11))
                    .foregroundStyle(t.muted)

                ToggleRow(label: "Allow persistent website data", isOn: $persistentWebsiteDataEnabled)
                    .onChange(of: persistentWebsiteDataEnabled) { _, value in
                        AppSettings.shared.browserPersistentWebsiteDataEnabled = value
                    }

                Text(
                    "When off, browser tabs use an ephemeral data store to avoid system WebCrypto/Keychain prompts. Changes apply to new browser tabs."
                )
                .font(.system(size: 11))
                .foregroundStyle(t.muted)

                HStack(spacing: 8) {
                    Text("Terminal links")
                        .font(.system(size: 12))
                        .foregroundStyle(t.text)
                        .frame(width: 120, alignment: .leading)
                    Picker("", selection: $linkOpenMode) {
                        ForEach(LinkOpenMode.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onChange(of: linkOpenMode) { _, v in AppSettings.shared.linkOpenMode = v }
                }
            }

            // MARK: History
            Section(title: "History") {
                ToggleRow(label: "Save browsing history", isOn: $historyEnabled)
                    .onChange(of: historyEnabled) { _, v in AppSettings.shared.browserHistoryEnabled = v }

                HStack(spacing: 8) {
                    Text("Keep up to")
                        .font(.system(size: 12))
                        .foregroundStyle(t.text)
                    TextField("5000", value: $historyLimit, format: .number)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(t.text)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(width: 70)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(t.border, lineWidth: 1)
                        )
                        .onChange(of: historyLimit) { _, v in
                            AppSettings.shared.browserHistoryLimit = max(1, v)
                        }
                    Text("entries")
                        .font(.system(size: 12))
                        .foregroundStyle(t.text)
                    Spacer()
                    Button("Clear All…") { showClearConfirm = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .confirmationDialog(
                            "Clear all browser history?",
                            isPresented: $showClearConfirm,
                            titleVisibility: .visible
                        ) {
                            Button("Clear History", role: .destructive) {
                                BrowserHistory.shared.clear()
                                historyEntries = BrowserHistory.shared.entries
                            }
                            Button("Cancel", role: .cancel) {}
                        }
                }
            }

            // MARK: History List
            if historyEnabled {
                Section(title: "Recent History") {
                    TextField("Search history…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(t.text)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(t.border, lineWidth: 1)
                        )

                    if filteredEntries.isEmpty {
                        Text(historyEntries.isEmpty ? "No history yet." : "No results.")
                            .font(.system(size: 12))
                            .foregroundStyle(t.muted)
                            .padding(.vertical, 4)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(filteredEntries.prefix(200)) { entry in
                                HistoryRow(entry: entry, t: t) {
                                    BrowserHistory.shared.remove(id: entry.id)
                                    historyEntries = BrowserHistory.shared.entries
                                }
                                if entry.id != filteredEntries.prefix(200).last?.id {
                                    Divider()
                                        .background(t.border.opacity(0.4))
                                }
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(t.border.opacity(0.5), lineWidth: 0.5)
                        )

                        if filteredEntries.count > 200 {
                            Text("Showing 200 of \(filteredEntries.count) entries.")
                                .font(.system(size: 11))
                                .foregroundStyle(t.muted)
                        }
                    }
                }
            }
        }
        .foregroundStyle(t.text)
        .onAppear { loadHistory() }
        .onReceive(NotificationCenter.default.publisher(for: .browserHistoryChanged)) { _ in
            loadHistory()
        }
    }

    private func save() {
        AppSettings.shared.browserHomePage = homePage.trimmingCharacters(in: .whitespaces)
    }

    private func loadHistory() {
        historyEntries = BrowserHistory.shared.entries
    }
}

// MARK: - History Row

private struct HistoryRow: View {
    let entry: BrowserHistoryEntry
    let t: Tokens
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.system(size: 12))
                    .foregroundStyle(t.text)
                    .lineLimit(1)
                Text(entry.url.absoluteString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(t.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(entry.visitedAt, style: .relative)
                .font(.system(size: 10))
                .foregroundStyle(t.muted)
            if isHovered {
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(t.muted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}
