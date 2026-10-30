import Cocoa
import Security
import SwiftUI

/// macOS privacy (TCC) status and shortcuts into System Settings. Programs run
/// in a terminal are attributed to Boo, so their folder and automation prompts
/// show up as Boo's.
struct PermissionsSettingsView: View {
    @Environment(\.tokens) private var tokens
    private let signature = CodeSignatureInfo.current
    @State private var fullDiskAccess = PrivacyStatus.hasFullDiskAccess()

    var body: some View {
        let t = tokens

        SettingsPage(title: "Permissions") {
            Section(
                title: "Code Signature",
                footer:
                    "macOS remembers permissions per code signature. An ad-hoc signature changes with every build, "
                    + "so each update asks again."
            ) {
                SettingRow(label: "Signed by") {
                    status(
                        ok: !signature.isAdhoc,
                        text: signature.isAdhoc ? "Ad-hoc (permissions reset on update)" : signature.signer)
                }
            }

            Section(
                title: "Privacy",
                footer:
                    "Changes apply to programs started afterwards. Boo rechecks when you switch back to it."
            ) {
                SettingRow(
                    label: "Full Disk Access",
                    help:
                        "Covers Desktop, Documents, Downloads, iCloud Drive and external volumes for everything run in Boo, "
                        + "so shells and tools stop triggering folder prompts."
                ) {
                    HStack(spacing: 8) {
                        status(ok: fullDiskAccess, text: fullDiskAccess ? "Granted" : "Not granted")
                        openButton(PrivacyPane.fullDiskAccess)
                    }
                }
                SettingRow(
                    label: "Files and Folders",
                    help: "Per-folder grants, if you'd rather not give Full Disk Access."
                ) {
                    openButton(PrivacyPane.filesAndFolders)
                }
                SettingRow(
                    label: "Developer Tools",
                    help:
                        "Add Boo with + to let programs built or downloaded in the terminal skip the first-launch "
                        + "security scan."
                ) {
                    openButton(PrivacyPane.developerTools)
                }
                SettingRow(
                    label: "Automation",
                    help: "Scripts run with osascript ask once per app they control."
                ) {
                    openButton(PrivacyPane.automation)
                }
            }
        }
        .foregroundStyle(t.text)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fullDiskAccess = PrivacyStatus.hasFullDiskAccess()
        }
    }

    private func status(ok: Bool, text: String) -> some View {
        let t = tokens
        return HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? t.success : t.warning)
                .font(.system(size: 12))
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(t.muted)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func openButton(_ pane: String) -> some View {
        Button("Open…") {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                NSWorkspace.shared.open(url)
            }
        }
        .buttonStyle(.themed)
    }
}

private enum PrivacyPane {
    static let fullDiskAccess = "Privacy_AllFiles"
    static let filesAndFolders = "Privacy_FilesAndFolders"
    static let developerTools = "Privacy_DevTools"
    static let automation = "Privacy_Automation"
}

enum PrivacyStatus {
    /// There is no API for Full Disk Access; the user's TCC database is readable
    /// only with it. Opening it never prompts.
    static func hasFullDiskAccess() -> Bool {
        let path = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }
}

struct CodeSignatureInfo {
    let isAdhoc: Bool
    let signer: String

    /// Read once: the running binary's signature can't change.
    static let current = read()

    private static func read() -> CodeSignatureInfo {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
            SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
            SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess,
            let dict = info as? [String: Any]
        else { return CodeSignatureInfo(isAdhoc: true, signer: "Unsigned") }

        let flags = (dict[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        let adhoc = flags & SecCodeSignatureFlags.adhoc.rawValue != 0
        let leaf = (dict[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first
        let name = leaf.flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? "Unknown"
        return CodeSignatureInfo(isAdhoc: adhoc || leaf == nil, signer: name)
    }
}
