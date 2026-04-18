import SwiftUI

struct SnippetsPanelView: View {
    @ObservedObject var settings = SettingsObserver(topics: [.theme])
    var fontScale: SidebarFontScale = SidebarFontScale(base: AppSettings.shared.sidebarFontSize)
    @State private var snippets: [SnippetService.Snippet] = []
    @State private var isAdding = false
    @State private var editingSnippet: SnippetService.Snippet?

    var onRun: ((String) -> Void)?
    var onPaste: ((String) -> Void)?

    var body: some View {
        let _ = settings.revision
        let theme = AppSettings.shared.theme
        let mutedColor = Color(nsColor: theme.chromeMuted)
        let textColor = Color(nsColor: theme.chromeText)
        let accentColor = Color(nsColor: theme.accentColor)

        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "text.page.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(accentColor)
                Text("SNIPPETS")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(mutedColor)
                    .tracking(0.8)

                Spacer()

                Button(action: { isAdding = true }) {
                    Image(systemName: "plus")
                        .font(.system(size: 10))
                        .foregroundStyle(mutedColor)
                }
                .buttonStyle(.plain)
                .help("Add snippet")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if snippets.isEmpty && !isAdding {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "text.page")
                        .font(.system(size: 24))
                        .foregroundStyle(mutedColor.opacity(0.3))
                    Text("No snippets yet")
                        .font(fontScale.font(.base))
                        .foregroundStyle(mutedColor.opacity(0.5))
                    Text("Add commands you use often")
                        .font(fontScale.font(.xs))
                        .foregroundStyle(mutedColor.opacity(0.35))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if isAdding {
                            SnippetEditRow(
                                fontScale: fontScale,
                                textColor: textColor,
                                mutedColor: mutedColor,
                                accentColor: accentColor,
                                onSave: { name, command, description in
                                    SnippetService.shared.add(
                                        name: name, command: command,
                                        description: description)
                                    isAdding = false
                                    refreshSnippets()
                                },
                                onCancel: { isAdding = false }
                            )
                        }

                        ForEach(snippets) { snippet in
                            if editingSnippet?.id == snippet.id {
                                SnippetEditRow(
                                    fontScale: fontScale,
                                    textColor: textColor,
                                    mutedColor: mutedColor,
                                    accentColor: accentColor,
                                    initialName: snippet.name,
                                    initialCommand: snippet.command,
                                    initialDescription: snippet.description,
                                    onSave: { name, command, description in
                                        SnippetService.shared.update(
                                            id: snippet.id, name: name,
                                            command: command,
                                            description: description)
                                        editingSnippet = nil
                                        refreshSnippets()
                                    },
                                    onCancel: { editingSnippet = nil }
                                )
                            } else {
                                SnippetRow(
                                    snippet: snippet,
                                    fontScale: fontScale,
                                    textColor: textColor,
                                    mutedColor: mutedColor,
                                    accentColor: accentColor,
                                    onRun: { onRun?(snippet.command) },
                                    onPaste: { onPaste?(snippet.command) },
                                    onEdit: { editingSnippet = snippet },
                                    onRemove: {
                                        SnippetService.shared.remove(id: snippet.id)
                                        refreshSnippets()
                                    }
                                )
                            }
                        }
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .background(Color(nsColor: theme.sidebarBg))
        .onAppear { refreshSnippets() }
    }

    private func refreshSnippets() {
        snippets = SnippetService.shared.snippets
    }
}

// MARK: - Snippet Row

struct SnippetRow: View {
    let snippet: SnippetService.Snippet
    let fontScale: SidebarFontScale
    let textColor: Color
    let mutedColor: Color
    let accentColor: Color
    let onRun: () -> Void
    let onPaste: () -> Void
    let onEdit: () -> Void
    let onRemove: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 10))
                .foregroundStyle(mutedColor.opacity(0.6))
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(snippet.name)
                    .font(fontScale.font(.base).weight(.medium))
                    .foregroundStyle(textColor)
                    .lineLimit(1)

                Text(snippet.command)
                    .font(.system(size: fontScale.size(.xs), design: .monospaced))
                    .foregroundStyle(accentColor.opacity(0.7))
                    .lineLimit(1)

                if !snippet.description.isEmpty {
                    Text(snippet.description)
                        .font(fontScale.font(.xs))
                        .foregroundStyle(mutedColor.opacity(0.5))
                        .lineLimit(1)
                }
            }

            Spacer()

            if isHovered {
                Button(action: onRun) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(accentColor)
                }
                .buttonStyle(.plain)
                .help("Run in terminal")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? mutedColor.opacity(0.1) : Color.clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onRun() }
        .contextMenu {
            Button("Run") { onRun() }
            Button("Paste without running") { onPaste() }
            Divider()
            Button("Edit") { onEdit() }
            Button("Remove") { onRemove() }
        }
    }
}

// MARK: - Snippet Edit Row

struct SnippetEditRow: View {
    let fontScale: SidebarFontScale
    let textColor: Color
    let mutedColor: Color
    let accentColor: Color
    var initialName: String = ""
    var initialCommand: String = ""
    var initialDescription: String = ""
    let onSave: (String, String, String) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var command: String = ""
    @State private var description: String = ""

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !command.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section label
            HStack(spacing: 4) {
                Image(systemName: "pencil")
                    .font(.system(size: 8))
                    .foregroundStyle(accentColor.opacity(0.7))
                Text(initialName.isEmpty ? "NEW SNIPPET" : "EDIT SNIPPET")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(mutedColor.opacity(0.6))
                    .tracking(0.5)
                Spacer()
            }
            .padding(.bottom, 8)

            // Name field
            TextField("Name", text: $name)
                .textFieldStyle(.plain)
                .font(fontScale.font(.base))
                .foregroundStyle(textColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(mutedColor.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(mutedColor.opacity(0.12), lineWidth: 0.5)
                )
                .padding(.bottom, 6)

            // Command field (monospaced code style)
            TextField("Command", text: $command)
                .textFieldStyle(.plain)
                .font(.system(size: fontScale.size(.xs), design: .monospaced))
                .foregroundStyle(accentColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(accentColor.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(accentColor.opacity(0.12), lineWidth: 0.5)
                )
                .padding(.bottom, 6)

            // Description field
            TextField("Description (optional)", text: $description)
                .textFieldStyle(.plain)
                .font(fontScale.font(.xs))
                .foregroundStyle(mutedColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(mutedColor.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(mutedColor.opacity(0.1), lineWidth: 0.5)
                )
                .padding(.bottom, 8)

            // Action buttons
            HStack(spacing: 6) {
                Spacer()
                Button("Cancel") { onCancel() }
                    .buttonStyle(.plain)
                    .font(fontScale.font(.xs))
                    .foregroundStyle(mutedColor.opacity(0.7))

                Button("Save") {
                    let trimmedName = name.trimmingCharacters(in: .whitespaces)
                    let trimmedCommand = command.trimmingCharacters(in: .whitespaces)
                    guard !trimmedName.isEmpty, !trimmedCommand.isEmpty else { return }
                    onSave(
                        trimmedName, trimmedCommand,
                        description.trimmingCharacters(in: .whitespaces))
                }
                .buttonStyle(.plain)
                .font(fontScale.font(.xs).weight(.semibold))
                .foregroundStyle(canSave ? accentColor : accentColor.opacity(0.3))
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            canSave
                                ? accentColor.opacity(0.15) : accentColor.opacity(0.05))
                )
                .disabled(!canSave)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(mutedColor.opacity(0.06))
                .padding(.horizontal, 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(mutedColor.opacity(0.12), lineWidth: 0.5)
                .padding(.horizontal, 4)
        )
        .onAppear {
            name = initialName
            command = initialCommand
            description = initialDescription
        }
    }
}
