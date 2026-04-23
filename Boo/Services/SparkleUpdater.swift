import Cocoa
import Sparkle

@MainActor
final class SparkleUpdater {
    static let shared = SparkleUpdater()

    private let controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    private var hasStarted = false

    private init() {}

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var isConfigured: Bool {
        guard let info = Bundle.main.infoDictionary else { return false }
        let feedURL = (info["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let publicKey = (info["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return !(feedURL?.isEmpty ?? true) && !(publicKey?.isEmpty ?? true)
    }

    func start() {
        guard isConfigured, !hasStarted else { return }
        controller.startUpdater()
        hasStarted = true
    }

    func checkForUpdates() {
        guard isConfigured else { return }
        start()
        controller.checkForUpdates(nil)
    }
}
