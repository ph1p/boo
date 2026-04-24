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
            Section(title: "General") {
                SettingRow(
                    label: "Home page",
                    help: "Opened when creating a new browser tab."
                ) {
                    SettingTextField(
                        placeholder: "https://google.com",
                        text: $homePage,
                        monospaced: true,
                        onCommit: save
                    )
                    .onChange(of: homePage) { _, _ in save() }
                }

                ToggleRow(
                    label: "Allow persistent website data",
                    help:
                        "When off, browser tabs use an ephemeral data store to avoid system WebCrypto/Keychain prompts. Changes apply to new browser tabs.",
                    isOn: $persistentWebsiteDataEnabled
                )
                .onChange(of: persistentWebsiteDataEnabled) { _, value in
                    AppSettings.shared.browserPersistentWebsiteDataEnabled = value
                }

                SettingRow(label: "Terminal links") {
                    Picker("", selection: $linkOpenMode) {
                        ForEach(LinkOpenMode.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220, alignment: .leading)
                    .onChange(of: linkOpenMode) { _, v in AppSettings.shared.linkOpenMode = v }
                }
            }

            Section(title: "History") {
                ToggleRow(label: "Save browsing history", isOn: $historyEnabled)
                    .onChange(of: historyEnabled) { _, v in AppSettings.shared.browserHistoryEnabled = v }

                SettingRow(label: "History limit", help: "Older entries are removed automatically.") {
                    HStack(spacing: 8) {
                        SettingNumberField(
                            value: $historyLimit,
                            width: 80,
                            alignment: .leading,
                            onCommit: { v in AppSettings.shared.browserHistoryLimit = max(1, v) }
                        )
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
            }

            if historyEnabled {
                Section(title: "Recent History") {
                    SettingTextField(
                        placeholder: "Search history…",
                        text: $searchText,
                        icon: "magnifyingglass",
                        trailingClear: true
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
                            DescriptionLabel(text: "Showing 200 of \(filteredEntries.count) entries.")
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
                IconButton(systemName: "xmark", size: 10, frame: 20, fillOpacity: 0, action: onDelete)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}
