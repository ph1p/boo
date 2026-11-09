import AppKit
import Combine

/// Accounts, vaults and items from the 1Password CLI (`op`). Secrets are never
/// kept: each copy, type or reference fetches the one item it needs, then drops it.
@MainActor
final class OnePasswordStore: ObservableObject {
    static let shared = OnePasswordStore()
    static let pluginID = "1password"
    static let linkOpenModeKey = "linkOpenMode"
    /// Set by the plugin: opens a URL in a Boo browser tab.
    var openInBrowserTab: ((URL) -> Void)?
    /// How long a copied secret stays on the clipboard.
    static let clipboardClearDelay: TimeInterval = 90
    /// Items older than this reload when the panel appears.
    static let staleAfter: TimeInterval = 15 * 60
    static let recentLimit = 5
    static let runPrefix = "op run --env-file=.env -- "
    /// `op` waits for Touch ID or the account password in the 1Password app.
    nonisolated static let timeout: TimeInterval = 120
    private static let vaultKey = "onePasswordVaultID"
    private static let accountKey = "onePasswordAccountID"
    private static let recentKey = "onePasswordRecentIDs"

    @Published private(set) var opPath: String?
    @Published private(set) var accounts: [OPAccount] = []
    @Published private(set) var vaults: [OPVault] = []
    @Published private(set) var items: [OPItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    /// Fields without secret values, per expanded item ID.
    @Published private(set) var details: [String: [OPField]] = [:]
    @Published private(set) var loadingDetails: Set<String> = []
    /// When the copied secret leaves the clipboard; nil when none is pending.
    @Published private(set) var clipboardClearsAt: Date?
    /// Item IDs, most recently used first.
    @Published private(set) var recentIDs: [String] =
        UserDefaults.standard.stringArray(forKey: OnePasswordStore.recentKey) ?? []
    /// nil shows every vault.
    @Published var vaultID: String? = UserDefaults.standard.string(forKey: OnePasswordStore.vaultKey) {
        didSet { UserDefaults.standard.set(vaultID, forKey: Self.vaultKey) }
    }
    /// nil uses `op`'s default account.
    @Published private(set) var accountID: String? = UserDefaults.standard.string(
        forKey: OnePasswordStore.accountKey)

    private var loaded = false
    private var lastLoaded: Date?
    private var clipboardClear: DispatchWorkItem?

    var isEnabled: Bool { AppSettings.shared.isPluginEnabled(Self.pluginID) }

    var visibleItems: [OPItem] {
        guard let vaultID else { return items }
        return items.filter { $0.vaultID == vaultID }
    }

    var needsSignIn: Bool { error.map(OPParser.needsSignIn) ?? false }

    /// Loads everything once; `reload` refreshes it.
    func start() {
        guard !loaded else { return }
        loaded = true
        reload()
    }

    /// Reloads when the items are older than `staleAfter`.
    func refreshIfStale() {
        guard loaded else { return start() }
        if let lastLoaded, Date().timeIntervalSince(lastLoaded) > Self.staleAfter { reload() }
    }

    func selectAccount(_ id: String?) {
        guard id != accountID else { return }
        accountID = id
        UserDefaults.standard.set(id, forKey: Self.accountKey)
        vaultID = nil
        details = [:]
        reload()
    }

    func reload() {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        let account = accountID
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.load(account: account)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { OnePasswordStore.shared.apply(result) }
            }
        }
    }

    private struct LoadResult: Sendable {
        var op: String?
        var accounts: [OPAccount] = []
        var vaults: [OPVault] = []
        var items: [OPItem] = []
        var error: String?
    }

    private func apply(_ result: LoadResult) {
        isLoading = false
        opPath = result.op
        error = result.error
        accounts = result.accounts
        if let id = accountID, !result.accounts.isEmpty, !result.accounts.contains(where: { $0.id == id }) {
            accountID = nil
            UserDefaults.standard.removeObject(forKey: Self.accountKey)
        }
        guard result.error == nil else { return }
        lastLoaded = Date()
        vaults = result.vaults
        items = result.items
        details = details.filter { id, _ in result.items.contains { $0.id == id } }
        if let id = vaultID, !result.vaults.contains(where: { $0.id == id }) { vaultID = nil }
    }

    private nonisolated static func load(account: String?) -> LoadResult {
        guard let op = findOp() else { return LoadResult(error: "op CLI not found") }
        var result = LoadResult(op: op)
        // Lists what is set up on this Mac; needs no unlock.
        if case .success(let data) = run(op, ["account", "list", "--format", "json"]) {
            result.accounts = OPParser.accounts(data)
        }
        // A stored account that is gone falls back to the default one.
        let account = account.flatMap { id in result.accounts.contains { $0.id == id } ? id : nil }
        let vaults = run(op, ["vault", "list", "--format", "json"], account: account)
        guard case .success(let vaultData) = vaults else {
            result.error = vaults.error
            return result
        }
        let items = run(op, ["item", "list", "--format", "json"], account: account)
        guard case .success(let itemData) = items else {
            result.error = items.error
            return result
        }
        var favorites = Set<String>()
        if case .success(let data) = run(op, ["item", "list", "--favorite", "--format", "json"], account: account) {
            favorites = Set(OPParser.items(data).map(\.id))
        }
        result.vaults = OPParser.vaults(vaultData)
        result.items = OPParser.items(itemData).map { item in
            var item = item
            item.favorite = item.favorite || favorites.contains(item.id)
            return item
        }
        return result
    }

    // MARK: - Details

    /// Loads the fields of `item`, without secret values, for the expanded row.
    /// Fetches the item's fields once (concealed values are not revealed), then
    /// calls `then`. A failed fetch shows an alert and skips `then`; a second
    /// call while one runs is dropped.
    func loadDetails(_ item: OPItem, then: (@MainActor () -> Void)? = nil) {
        if details[item.id] != nil {
            then?()
            return
        }
        guard !loadingDetails.contains(item.id) else { return }
        loadingDetails.insert(item.id)
        fetch(item, reveal: false) { fields in
            OnePasswordStore.shared.details[item.id] = fields.filter(\.isShown)
            then?()
        } done: {
            OnePasswordStore.shared.loadingDetails.remove(item.id)
        }
    }

    // MARK: - Actions

    /// Copies `secret` of `item`; the clipboard is cleared after `clipboardClearDelay`.
    func copy(_ secret: OPSecret, of item: OPItem) {
        reveal(item, label: secret.title, read: { secret.value(in: $0) }) { value in
            OnePasswordStore.shared.copyConcealed(value, label: "\(secret.title.lowercased()) of \(item.title)")
        }
    }

    /// Types `secret` of `item` into the focused terminal, as if keyed in.
    /// Meant for password prompts, where the terminal does not echo input.
    func type(_ secret: OPSecret, of item: OPItem, pressReturn: Bool = false) {
        reveal(item, label: secret.title, read: { secret.value(in: $0) }) { value in
            Self.sendToTerminal(pressReturn ? value + "\r" : value)
        }
    }

    func copy(_ field: OPField, of item: OPItem) {
        secret(of: field, in: item) { value in
            OnePasswordStore.shared.copyConcealed(value, label: "\(field.displayLabel) of \(item.title)")
        }
    }

    func type(_ field: OPField, of item: OPItem, pressReturn: Bool = false) {
        secret(of: field, in: item) { value in
            Self.sendToTerminal(pressReturn ? value + "\r" : value)
        }
    }

    /// Inserts the `op://` reference of `secret` (for `op read`, `op run`, `op inject`).
    func insertReference(_ secret: OPSecret, of item: OPItem, asRead: Bool = false) {
        fetch(item, reveal: false) { fields in
            guard let field = secret.field(in: fields) else {
                BooAlert.showTransient("\(item.title) has no \(secret.title.lowercased())")
                return
            }
            OnePasswordStore.shared.insertReference(field, of: item, asRead: asRead)
        }
    }

    func insertReference(_ field: OPField, of item: OPItem, asRead: Bool = false) {
        guard let reference = field.reference else {
            BooAlert.showTransient("\(field.displayLabel) has no op:// reference")
            return
        }
        noteUse(item)
        Self.sendToTerminal(asRead ? "op read \(shellEscape(reference))" : reference)
    }

    /// Inserts `op run --env-file=.env -- `, ready for the command to run.
    func insertRunPrefix() {
        Self.sendToTerminal(Self.runPrefix)
    }

    /// Opens the item's website in a Boo browser tab or the default browser,
    /// per the plugin's `linkOpenMode` setting.
    func openURL(of item: OPItem) {
        guard let url = item.webURL else { return }
        noteUse(item)
        let raw = AppSettings.shared.pluginString(
            Self.pluginID, Self.linkOpenModeKey, default: LinkOpenMode.browserTab.rawValue)
        if LinkOpenMode(rawValue: raw) != .externalBrowser, let openInBrowserTab {
            openInBrowserTab(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens the 1Password app, where the CLI integration is turned on.
    func openApp() {
        for id in ["com.1password.1password", "com.agilebits.onepassword7"] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
                return
            }
        }
        BooAlert.showTransient("1Password app not found")
    }

    func clearClipboardNow() {
        clipboardClear?.perform()
    }

    private static func sendToTerminal(_ text: String) {
        guard let controller = WindowManager.shared.activeController else { return }
        controller.sendRawToActivePane(text)
    }

    /// Plain fields need no fetch; concealed ones are read with `--reveal`.
    private func secret(of field: OPField, in item: OPItem, then: @escaping @MainActor (String) -> Void) {
        if !field.isConcealed, let value = field.secret {
            noteUse(item)
            then(value)
            return
        }
        reveal(
            item, label: field.displayLabel,
            read: { fields in
                fields.first { $0.id == field.id && $0.section == field.section }?.secret
            }, then: then)
    }

    private func reveal(
        _ item: OPItem, label: String, read: @escaping @Sendable ([OPField]) -> String?,
        then: @escaping @MainActor (String) -> Void
    ) {
        fetch(item, reveal: true) { fields in
            guard let value = read(fields) else {
                BooAlert.showTransient("\(item.title) has no \(label.lowercased())")
                return
            }
            OnePasswordStore.shared.noteUse(item)
            then(value)
        }
    }

    /// Runs `op item get` for `item` off the main thread; `then` gets its fields.
    private func fetch(
        _ item: OPItem, reveal: Bool, then: @escaping @MainActor ([OPField]) -> Void,
        done: @escaping @MainActor () -> Void = {}
    ) {
        guard let op = opPath ?? Self.findOp() else {
            BooAlert.showTransient("op CLI not found")
            done()
            return
        }
        var args = ["item", "get", item.id, "--format", "json"]
        if !item.vaultID.isEmpty { args += ["--vault", item.vaultID] }
        if reveal { args.append("--reveal") }
        let account = accountID
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.run(op, args, account: account)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    done()
                    switch result {
                    case .success(let data): then(OPParser.fields(data))
                    case .failure(let message): BooAlert.showTransient(message)
                    }
                }
            }
        }
    }

    private func noteUse(_ item: OPItem) {
        var ids = recentIDs.filter { $0 != item.id }
        ids.insert(item.id, at: 0)
        recentIDs = Array(ids.prefix(Self.recentLimit))
        UserDefaults.standard.set(recentIDs, forKey: Self.recentKey)
    }

    /// Puts `value` on the clipboard marked concealed (clipboard managers skip
    /// it), and clears it later unless something else was copied since.
    private func copyConcealed(_ value: String, label: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let count = pasteboard.changeCount
        clipboardClear?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                if pasteboard.changeCount == count { pasteboard.clearContents() }
                OnePasswordStore.shared.clipboardClearsAt = nil
                OnePasswordStore.shared.clipboardClear = nil
            }
        }
        clipboardClear = work
        clipboardClearsAt = Date().addingTimeInterval(Self.clipboardClearDelay)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.clipboardClearDelay, execute: work)
        BooAlert.showTransient("Copied \(label)")
    }

    // MARK: - CLI

    enum RunResult: Sendable {
        case success(Data)
        case failure(String)

        var error: String? {
            if case .failure(let message) = self { return message }
            return nil
        }
    }

    nonisolated static func run(_ op: String, _ args: [String], account: String? = nil) -> RunResult {
        let args = account.map { args + ["--account", $0] } ?? args
        guard let result = Subprocess.run(op, args, environment: environment(), timeout: timeout) else {
            return .failure("op timed out")
        }
        guard result.status == 0 else {
            let message = OPParser.errorMessage(result.stderr)
            return .failure(message.isEmpty ? "op exited with \(result.status)" : message)
        }
        return .success(Data(result.stdout.utf8))
    }

    nonisolated static func findOp(wait: Bool = true) -> String? {
        let path = environment(wait: wait)["PATH"] ?? ""
        return BinaryScanner.path(of: "op", in: path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin")
    }

    /// The login-shell environment, so `OP_ACCOUNT` and friends apply.
    nonisolated static func environment(wait: Bool = true) -> [String: String] {
        let home = NSHomeDirectory()
        return LoginShellEnvironment.shared.environment(
            wait: wait, extraPaths: ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin"])
    }
}
