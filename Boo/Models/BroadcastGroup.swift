import Foundation

/// Keyboard input typed into one terminal, as it is replayed into the others.
enum BroadcastInput: Equatable {
    /// A key event with the raw values of `ghostty_input_key_s`.
    case key(action: UInt32, keyCode: UInt32, mods: UInt32, consumedMods: UInt32, unshiftedCodepoint: UInt32, text: String?)
    /// Pasted text or an IME commit.
    case text(String)
}

@MainActor
protocol BroadcastReceiver: AnyObject {
    func receiveBroadcast(_ input: BroadcastInput)
}

/// The panes of one workspace that receive each other's typing. Panes whose
/// front tab is not a plain terminal (an agent, a browser…) never take part.
@MainActor
final class BroadcastGroup {
    enum Mode: Equatable {
        /// Every eligible pane, including ones split off later.
        case all
        /// Panes picked with ⌘-click.
        case selected(Set<UUID>)
    }

    let workspaceID: UUID
    private(set) var mode: Mode
    /// Set once the group reached two members; from then on, dropping to
    /// one ends the broadcast. A fresh "Selected Panes" group starts with one.
    private var hadPeers = false

    init(workspaceID: UUID, mode: Mode) {
        self.workspaceID = workspaceID
        self.mode = mode
    }

    var isSelecting: Bool {
        if case .selected = mode { return true }
        return false
    }

    /// Adds or removes `paneID` from a "Selected Panes" group.
    func toggle(_ paneID: UUID) {
        guard case .selected(var panes) = mode else { return }
        if panes.remove(paneID) == nil { panes.insert(paneID) }
        mode = .selected(panes)
    }

    /// The members among `panes` (in their order), given which are eligible.
    func members(of panes: [UUID], isEligible: (UUID) -> Bool) -> [UUID] {
        panes.filter { pane in
            guard isEligible(pane) else { return false }
            if case .selected(let picked) = mode { return picked.contains(pane) }
            return true
        }
    }

    /// Records the current member count; true when the group shrank to one.
    func shrankToOne(memberCount: Int) -> Bool {
        if memberCount >= 2 { hadPeers = true }
        return hadPeers && memberCount < 2
    }

    /// Replays `input` from `source` into every other member. Nothing is sent
    /// when `source` is not a member, so typing elsewhere stays private.
    static func fanOut(
        _ input: BroadcastInput, from source: UUID, members: [UUID], receiver: (UUID) -> BroadcastReceiver?
    ) {
        guard members.contains(source) else { return }
        for pane in members where pane != source {
            receiver(pane)?.receiveBroadcast(input)
        }
    }
}
