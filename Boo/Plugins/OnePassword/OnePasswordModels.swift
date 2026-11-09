import Foundation

/// A 1Password account set up on this Mac, from `op account list --format json`.
struct OPAccount: Identifiable, Equatable {
    /// The account UUID, what `--account` takes.
    let id: String
    let email: String
    let url: String

    var title: String { email.isEmpty ? url : "\(email) · \(url)" }
}

/// A 1Password vault, from `op vault list --format json`.
struct OPVault: Identifiable, Equatable {
    let id: String
    let name: String
}

/// A 1Password item without secrets, from `op item list --format json`.
struct OPItem: Identifiable, Equatable {
    let id: String
    let title: String
    let category: String
    let vaultID: String
    let vaultName: String
    /// The username for logins, a hint for other categories.
    let detail: String
    /// The primary website.
    var url: String?
    var favorite = false

    var isLogin: Bool { category == "LOGIN" }

    var symbol: String {
        switch category {
        case "LOGIN": return "person.badge.key"
        case "PASSWORD": return "key"
        case "API_CREDENTIAL": return "chevron.left.forwardslash.chevron.right"
        case "SSH_KEY": return "terminal"
        case "SECURE_NOTE": return "note.text"
        case "CREDIT_CARD": return "creditcard"
        case "DATABASE": return "cylinder"
        case "SERVER": return "server.rack"
        case "IDENTITY": return "person.text.rectangle"
        case "DOCUMENT": return "doc"
        default: return "lock"
        }
    }

    /// `url` when it opens in a browser.
    var webURL: URL? {
        guard let url, var components = URLComponents(string: url) else { return nil }
        if components.scheme == nil {
            guard let fixed = URLComponents(string: "https://" + url) else { return nil }
            components = fixed
        }
        guard components.scheme == "https" || components.scheme == "http" else { return nil }
        return components.url
    }

    /// Case-insensitive; `query` is lowercased by the caller.
    func matches(_ query: String) -> Bool {
        query.isEmpty || title.lowercased().contains(query) || detail.lowercased().contains(query)
            || vaultName.lowercased().contains(query) || (url?.lowercased().contains(query) ?? false)
    }
}

/// A field of an item, from `op item get --format json`.
struct OPField: Identifiable, Equatable {
    let id: String
    let type: String
    let purpose: String
    let label: String
    let value: String?
    /// `op://vault/item/field`.
    let reference: String?
    /// The current one-time code of an OTP field.
    let totp: String?
    /// The label of the section the field is in.
    var section: String?

    var isOTP: Bool { type == "OTP" }
    /// Shown masked; its value needs `--reveal`.
    var isConcealed: Bool { type == "CONCEALED" || isOTP }

    /// The text copy and type use: the current code for OTP fields.
    var secret: String? {
        let text = isOTP ? totp : value
        return text?.isEmpty == false ? text : nil
    }

    /// Worth a row: concealed fields always (their value may be withheld), others when set.
    var isShown: Bool { isConcealed || secret != nil }

    var displayLabel: String {
        if !label.isEmpty { return label }
        switch purpose {
        case "USERNAME": return "username"
        case "PASSWORD": return "password"
        case "NOTES": return "notes"
        default: return id
        }
    }
}

/// The fields Boo can copy, type or reference without opening an item.
enum OPSecret: String, CaseIterable {
    case username, password, otp

    var title: String {
        switch self {
        case .username: return "Username"
        case .password: return "Password"
        case .otp: return "One-Time Code"
        }
    }

    /// The field of `fields` this secret reads: by purpose, then by type or label.
    func field(in fields: [OPField]) -> OPField? {
        switch self {
        case .username:
            return fields.first { $0.purpose == "USERNAME" }
                ?? fields.first { $0.label.lowercased() == "username" }
        case .password:
            return fields.first { $0.purpose == "PASSWORD" }
                ?? fields.first { $0.type == "CONCEALED" && $0.label.lowercased() == "password" }
                ?? fields.first { $0.type == "CONCEALED" && $0.label.lowercased() == "credential" }
                ?? fields.first { $0.type == "CONCEALED" }
        case .otp:
            return fields.first(where: \.isOTP)
        }
    }

    /// The text this secret puts on the clipboard or into the terminal.
    func value(in fields: [OPField]) -> String? {
        field(in: fields)?.secret
    }
}

/// Parses the JSON the `op` CLI prints. Unknown or malformed entries are skipped.
enum OPParser {
    static func accounts(_ data: Data) -> [OPAccount] {
        array(data).compactMap { object in
            guard let id = object["account_uuid"] as? String else { return nil }
            return OPAccount(
                id: id, email: object["email"] as? String ?? "", url: object["url"] as? String ?? "")
        }
    }

    static func vaults(_ data: Data) -> [OPVault] {
        array(data).compactMap { object in
            guard let id = object["id"] as? String, let name = object["name"] as? String else { return nil }
            return OPVault(id: id, name: name)
        }
    }

    static func items(_ data: Data) -> [OPItem] {
        array(data).compactMap { object in
            guard let id = object["id"] as? String, let title = object["title"] as? String else { return nil }
            let vault = object["vault"] as? [String: Any]
            return OPItem(
                id: id, title: title, category: object["category"] as? String ?? "",
                vaultID: vault?["id"] as? String ?? "", vaultName: vault?["name"] as? String ?? "",
                detail: object["additional_information"] as? String ?? "",
                url: primaryURL(object["urls"]), favorite: object["favorite"] as? Bool ?? false)
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    static func fields(_ data: Data) -> [OPField] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let fields = object["fields"] as? [[String: Any]]
        else { return [] }
        return fields.compactMap { field in
            guard let id = field["id"] as? String else { return nil }
            let section = (field["section"] as? [String: Any])?["label"] as? String
            return OPField(
                id: id, type: field["type"] as? String ?? "", purpose: field["purpose"] as? String ?? "",
                label: field["label"] as? String ?? "", value: field["value"] as? String,
                reference: field["reference"] as? String, totp: field["totp"] as? String,
                section: section?.isEmpty == false ? section : nil)
        }
    }

    /// The last non-empty stderr line, without the `[ERROR] <timestamp>` prefix.
    static func errorMessage(_ stderr: String) -> String {
        let line =
            stderr.split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init) ?? ""
        guard line.hasPrefix("[ERROR]") else { return line.trimmingCharacters(in: .whitespaces) }
        // "[ERROR] 2026/11/09 10:00:00 message"
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        return parts.count == 4 ? String(parts[3]) : line
    }

    /// Whether `message` means `op` is not signed in or not linked to the app.
    static func needsSignIn(_ message: String) -> Bool {
        let text = message.lowercased()
        return ["not currently signed in", "no accounts configured", "sign in", "desktop app", "authorization"]
            .contains { text.contains($0) }
    }

    private static func primaryURL(_ value: Any?) -> String? {
        guard let urls = value as? [[String: Any]] else { return nil }
        let url = urls.first { $0["primary"] as? Bool == true } ?? urls.first
        return (url?["href"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func array(_ data: Data) -> [[String: Any]] {
        (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    }
}
