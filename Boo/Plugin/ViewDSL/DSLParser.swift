import Foundation

/// Parses JSON data/string into a DSLElement tree.
/// ADR-6: JSON → DSLElement tree.
struct DSLParser {

    struct ParseError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// Parse a JSON string into a DSL element tree.
    static func parse(_ jsonString: String) throws -> [DSLElement] {
        guard let data = jsonString.data(using: .utf8) else {
            throw ParseError(message: "Invalid UTF-8 in DSL JSON")
        }
        return try parse(data)
    }

    /// Parse JSON data into a DSL element tree.
    static func parse(_ data: Data) throws -> [DSLElement] {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ParseError(message: "Invalid JSON: \(error.localizedDescription)")
        }

        if let dict = json as? [String: Any] {
            return [try parseElement(dict, path: "$")]
        } else if let array = json as? [[String: Any]] {
            return try array.enumerated().map { try parseElement($1, path: "$[\($0)]") }
        } else {
            throw ParseError(message: "Expected JSON object or array at $")
        }
    }

    private static func parseElement(_ dict: [String: Any], path: String) throws -> DSLElement {
        guard let type = dict["type"] as? String else {
            throw ParseError(message: "Missing 'type' field at \(path)")
        }

        switch type {
        case "vstack":
            let children = try parseChildren(dict, path: path)
            return .vstack(children: children)

        case "hstack", "row":
            let children = try parseChildren(dict, path: path)
            return .hstack(children: children)

        case "label", "text":
            let text = dict["text"] as? String ?? dict["content"] as? String
            guard let text else {
                throw ParseError(message: "Missing 'text' or 'content' for \(type) at \(path)")
            }
            let style = (dict["style"] as? String).flatMap(DSLTextStyle.init(rawValue:))
            let tint = (dict["tint"] as? String).flatMap(DSLTint.init(rawValue:))
            return .label(text: text, style: style, tint: tint)

        case "icon":
            let name = dict["name"] as? String ?? dict["text"] as? String ?? "questionmark"
            let tint = (dict["tint"] as? String).flatMap(DSLTint.init(rawValue:))
            return .label(text: name, style: nil, tint: tint)

        case "list":
            guard let itemsJSON = dict["items"] as? [[String: Any]] else {
                throw ParseError(message: "Missing 'items' array for list at \(path)")
            }
            let items = try itemsJSON.enumerated().map { i, itemDict in
                try parseListItem(itemDict, path: "\(path).items[\(i)]")
            }
            return .list(items: items)

        case "button":
            guard let label = dict["label"] as? String else {
                throw ParseError(message: "Missing 'label' for button at \(path)")
            }
            guard let actionDict = dict["action"] as? [String: Any] else {
                throw ParseError(message: "Missing 'action' for button at \(path)")
            }
            let action = try parseAction(actionDict, path: "\(path).action")
            let style = (dict["style"] as? String).flatMap(DSLButtonStyle.init(rawValue:))
            let ctxMenu = try parseContextMenu(dict, path: path)
            return .button(label: label, action: action, style: style, contextMenu: ctxMenu)

        case "badge":
            guard let text = dict["text"] as? String ?? (dict["count"] as? Int).map(String.init) else {
                throw ParseError(message: "Missing 'text' or 'count' for badge at \(path)")
            }
            let tint = (dict["tint"] as? String).flatMap(DSLTint.init(rawValue:))
            let a11yLabel = dict["accessibilityLabel"] as? String
            return .badge(text: text, tint: tint, accessibilityLabel: a11yLabel)

        case "divider":
            return .divider

        case "spacer":
            return .spacer

        default:
            throw ParseError(message: "Unknown element type '\(type)' at \(path)")
        }
    }

    private static func parseChildren(_ dict: [String: Any], path: String) throws -> [DSLElement] {
        guard let children = dict["children"] as? [[String: Any]] else {
            return []
        }
        return try children.enumerated().map { try parseElement($1, path: "\(path).children[\($0)]") }
    }

    private static func parseListItem(_ dict: [String: Any], path: String) throws -> DSLListItem {
        guard let label = dict["label"] as? String else {
            throw ParseError(message: "Missing 'label' for list item at \(path)")
        }
        let icon = dict["icon"] as? String
        let tint = (dict["tint"] as? String).flatMap(DSLTint.init(rawValue:))
        let detail = dict["detail"] as? String
        let action: DSLAction?
        if let actionDict = dict["action"] as? [String: Any] {
            action = try parseAction(actionDict, path: "\(path).action")
        } else {
            action = nil
        }
        let ctxMenu = try parseContextMenu(dict, path: path)
        let a11yLabel = dict["accessibilityLabel"] as? String
        return DSLListItem(
            label: label, icon: icon, tint: tint, detail: detail, action: action,
            contextMenu: ctxMenu, accessibilityLabel: a11yLabel)
    }

    private static func parseContextMenu(_ dict: [String: Any], path: String) throws -> [DSLContextMenuItem]? {
        guard let menuItems = dict["contextMenu"] as? [[String: Any]] else { return nil }
        return try menuItems.enumerated().map { i, itemDict in
            guard let label = itemDict["label"] as? String else {
                throw ParseError(message: "Missing 'label' for contextMenu item at \(path).contextMenu[\(i)]")
            }
            guard let actionDict = itemDict["action"] as? [String: Any] else {
                throw ParseError(message: "Missing 'action' for contextMenu item at \(path).contextMenu[\(i)]")
            }
            let action = try parseAction(actionDict, path: "\(path).contextMenu[\(i)].action")
            let icon = itemDict["icon"] as? String
            let style = (itemDict["style"] as? String).flatMap(DSLButtonStyle.init(rawValue:))
            return DSLContextMenuItem(label: label, action: action, icon: icon, style: style)
        }
    }

    private static func parseAction(_ dict: [String: Any], path: String) throws -> DSLAction {
        guard let type = dict["type"] as? String else {
            throw ParseError(message: "Missing 'type' for action at \(path)")
        }
        return DSLAction(
            type: type,
            path: dict["path"] as? String,
            command: dict["command"] as? String,
            text: dict["text"] as? String,
            url: dict["url"] as? String,
            title: dict["title"] as? String
        )
    }
}
