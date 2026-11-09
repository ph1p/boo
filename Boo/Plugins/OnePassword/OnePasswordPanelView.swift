import SwiftUI

struct OnePasswordPanelView: View {
    @ObservedObject var settings = SettingsObserver(topics: [.theme])
    @ObservedObject var store = OnePasswordStore.shared
    var fontScale: SidebarFontScale = SidebarFontScale(base: AppSettings.shared.sidebarFontSize)
    @State private var filter = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let _ = settings.revision
        let t = Tokens.current
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()

        VStack(alignment: .leading, spacing: 0) {
            header(t)
            searchField(t)

            if store.needsSignIn {
                signInHelp(t)
            } else if let error = store.error {
                Text(error)
                    .font(fontScale.font(.sm))
                    .foregroundStyle(Color(nsColor: .systemRed).opacity(0.85))
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }

            let rows = rows(query: query)
            if rows.isEmpty {
                emptyState(t, query: query)
            } else {
                ScrollView {
                    // One flat ForEach with unique IDs: nested ForEach, conditional
                    // headers and one item in several groups made the LazyVStack
                    // misplace rows and leave blank gaps.
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(rows) { row in
                            switch row.kind {
                            case .header(let title):
                                groupHeader(title, t)
                            case .item(let item):
                                OnePasswordItemRow(
                                    item: item, showVault: store.vaultID == nil, fontScale: fontScale, t: t)
                            }
                        }
                    }
                    // Room for the clipboard footer, which overlays the list.
                    .padding(.bottom, 36)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // An overlay, not a stack row: resizing the scroll view under a
        // LazyVStack left a blank gap until the next scroll.
        .overlay(alignment: .bottom) {
            if store.clipboardClearsAt != nil {
                clipboardFooter(t)
            }
        }
        .background(t.bg)
        .onAppear { store.refreshIfStale() }
    }

    private struct Row: Identifiable {
        enum Kind {
            case header(String)
            case item(OPItem)
        }
        let id: String
        let kind: Kind
    }

    /// Favorites and recents above all items; one flat list while searching.
    private func rows(query: String) -> [Row] {
        let visible = store.visibleItems
        var groups: [(title: String, items: [OPItem])] = []
        if query.isEmpty {
            let favorites = visible.filter(\.favorite)
            if !favorites.isEmpty { groups.append(("Favorites", favorites)) }
            let byID = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let recent = store.recentIDs.compactMap { byID[$0] }
            if !recent.isEmpty { groups.append(("Recent", recent)) }
            groups.append(("All Items", visible))
        } else {
            groups.append(("Results", visible.filter { $0.matches(query) }))
        }
        groups.removeAll { $0.items.isEmpty }
        var rows: [Row] = []
        for group in groups {
            if groups.count > 1 { rows.append(Row(id: "h:" + group.title, kind: .header(group.title))) }
            rows += group.items.map { Row(id: group.title + ":" + $0.id, kind: .item($0)) }
        }
        return rows
    }

    // MARK: - Parts

    private func header(_ t: Tokens) -> some View {
        HStack(spacing: 4) {
            if store.accounts.count > 1 {
                Menu {
                    ForEach(store.accounts) { account in
                        Button {
                            store.selectAccount(account.id)
                        } label: {
                            if account.id == store.accountID {
                                Label(account.title, systemImage: "checkmark")
                            } else {
                                Text(account.title)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(t.muted)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(store.accounts.first { $0.id == store.accountID }?.title ?? "Default account")
            }

            Menu {
                Button {
                    store.vaultID = nil
                } label: {
                    if store.vaultID == nil {
                        Label("All Vaults", systemImage: "checkmark")
                    } else {
                        Text("All Vaults")
                    }
                }
                Divider()
                ForEach(store.vaults) { vault in
                    Button {
                        store.vaultID = vault.id
                    } label: {
                        if vault.id == store.vaultID {
                            Label(vault.name, systemImage: "checkmark")
                        } else {
                            Text(vault.name)
                        }
                    }
                }
            } label: {
                Text(store.vaults.first { $0.id == store.vaultID }?.name ?? "All Vaults")
                    .font(.system(size: fontScale.size(.sm), weight: .semibold))
                    .foregroundStyle(t.muted)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            if store.isLoading {
                ProgressView().controlSize(.mini)
            }

            Menu {
                Button("Insert op run Prefix") { store.insertRunPrefix() }
                Button("Open 1Password") { store.openApp() }
                Divider()
                Button("Reload") { store.reload() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(t.muted)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")

            Button(action: { store.reload() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(t.muted)
            }
            .buttonStyle(.plain)
            .disabled(store.isLoading)
            .help("Reload items")
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    /// Same look as the file tree's filter bar.
    private func searchField(_ t: Tokens) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(t.muted)
            TextField("Filter items", text: $filter)
                .textFieldStyle(.plain)
                .font(fontScale.font(.base))
                .foregroundStyle(t.text)
                .focused($searchFocused)
                .onKeyPress(.escape) {
                    filter = ""
                    searchFocused = false
                    return .handled
                }
            if !filter.isEmpty {
                Button(action: { filter = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(t.muted)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(t.controlFill))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(searchFocused ? t.accent.opacity(0.6) : .clear, lineWidth: 1)
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private func groupHeader(_ title: String, _ t: Tokens) -> some View {
        Text(title.uppercased())
            .font(.system(size: fontScale.size(.xs), weight: .semibold))
            .foregroundStyle(t.textTertiary)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func signInHelp(_ t: Tokens) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("op is not signed in")
                .font(fontScale.font(.base).weight(.semibold))
                .foregroundStyle(t.text)
            Text(
                "Turn on 1Password › Settings › Developer › Integrate with 1Password CLI, then reload."
            )
            .font(fontScale.font(.sm))
            .foregroundStyle(t.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            if let error = store.error {
                Text(error)
                    .font(fontScale.font(.sm))
                    .foregroundStyle(t.textTertiary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Button("Open 1Password") { store.openApp() }
                Button("Reload") { store.reload() }
                    .disabled(store.isLoading)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(t.subtleFill))
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private func emptyState(_ t: Tokens, query: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "key")
                .font(.system(size: 24))
                .foregroundStyle(t.textTertiary)
            Text(emptyText(query: query))
                .font(fontScale.font(.base))
                .foregroundStyle(t.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func emptyText(query: String) -> String {
        if store.isLoading { return "Loading…" }
        if store.error != nil { return "No items" }
        return query.isEmpty ? "No items" : "No matches"
    }

    private func clipboardFooter(_ t: Tokens) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, Int((store.clipboardClearsAt ?? context.date).timeIntervalSince(context.date).rounded()))
            HStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 11))
                    .foregroundStyle(t.muted)
                Text("Clipboard clears in \(left)s")
                    .font(fontScale.font(.sm))
                    .foregroundStyle(t.textSecondary)
                    .monospacedDigit()
                Spacer()
                Button("Clear Now") { store.clearClipboardNow() }
                    .buttonStyle(.plain)
                    .font(fontScale.font(.sm))
                    .foregroundStyle(t.accent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(t.subtleFill)
            .overlay(alignment: .top) { Rectangle().fill(t.separator).frame(height: 1) }
        }
    }
}
