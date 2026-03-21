import Foundation

/// ADR-6: Declarative view DSL element types.
/// 8 element types cover the vast majority of sidebar panel needs.

/// Semantic tint for themed color application.
enum DSLTint: String, Codable, Equatable {
    case success, error, warning, accent, muted
}

/// Text style variant.
enum DSLTextStyle: String, Codable, Equatable {
    case bold, muted, mono
}

/// Button style variant.
enum DSLButtonStyle: String, Codable, Equatable {
    case primary, secondary, destructive
}

/// An action attached to an interactive DSL element.
struct DSLAction: Codable, Equatable {
    let type: String  // "cd", "open", "exec", "copy", "reveal"
    let path: String?
    let command: String?
    let text: String?
}

/// A list item within a `list` element.
struct DSLListItem: Codable, Equatable {
    let label: String
    let icon: String?  // SF Symbol name
    let tint: DSLTint?
    let detail: String?
    let action: DSLAction?
    let accessibilityLabel: String?
}

/// The DSL element tree. Recursive via vstack/hstack children.
indirect enum DSLElement: Equatable {
    case vstack(children: [DSLElement])
    case hstack(children: [DSLElement])
    case label(text: String, style: DSLTextStyle?, tint: DSLTint?)
    case list(items: [DSLListItem])
    case button(label: String, action: DSLAction, style: DSLButtonStyle?)
    case badge(text: String, tint: DSLTint?, accessibilityLabel: String?)
    case divider
    case spacer
}
