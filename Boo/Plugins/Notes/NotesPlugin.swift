import SwiftUI

/// Built-in notes plugin: one markdown note per workspace plus a global
/// scratch note, edited in the sidebar and saved as you type.
@MainActor
final class NotesPlugin: BooPluginProtocol {
    var actions: PluginActions?
    var services: PluginServices?
    var hostActions: PluginHostActions?
    var onRequestCycleRerun: (() -> Void)?

    let manifest = PluginManifest(
        id: NotesStore.pluginID,
        name: "Notes",
        version: "1.0.0",
        icon: "note.text",
        description: "Markdown notes per workspace, saved to ~/.boo/notes",
        when: nil,
        runtime: nil,
        capabilities: PluginManifest.Capabilities(statusBarSegment: false, sidebarTab: true),
        statusBar: nil,
        settings: nil
    )

    var subscribedEvents: Set<PluginEvent> { [] }

    func sectionGeneration(context: PluginContext) -> UInt64 {
        SidebarSection.generation(for: [context.fontScale.generationKey])
    }

    /// A fresh panel per workspace note, so no picked note, search or editor
    /// state carries over from the previous workspace.
    func sectionIdentity(context: PluginContext) -> String? {
        NotesStore.activeNotePath()?.path
    }

    /// The editor scrolls itself.
    var prefersOuterScrollView: Bool { false }

    private let memory = NotesPanelMemory()

    func makeDetailView(context: PluginContext) -> AnyView? {
        guard let note = NotesStore.activeNotePath() else { return nil }
        return AnyView(
            NotesPanelView(path: note.path, title: note.title, memory: memory, fontScale: context.fontScale))
    }
}
