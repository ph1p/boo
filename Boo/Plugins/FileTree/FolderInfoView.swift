import SwiftUI

// MARK: - Folder Stats

struct FolderStats {
    let visibleCount: Int
    let hiddenCount: Int
    let totalSizeBytes: Int64

    var formattedSize: String {
        let bytes = Double(totalSizeBytes)
        if bytes < 1_024 { return "\(totalSizeBytes) B" }
        if bytes < 1_048_576 { return String(format: "%.1f KB", bytes / 1_024) }
        if bytes < 1_073_741_824 { return String(format: "%.1f MB", bytes / 1_048_576) }
        return String(format: "%.2f GB", bytes / 1_073_741_824)
    }

    static func compute(at path: String) -> FolderStats {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let keys: [URLResourceKey] = [.fileSizeKey, .isHiddenKey, .isRegularFileKey, .isDirectoryKey]
        guard
            let items = try? fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: keys, options: [])
        else { return FolderStats(visibleCount: 0, hiddenCount: 0, totalSizeBytes: 0) }

        var visible = 0
        var hidden = 0
        var totalSize: Int64 = 0

        for item in items {
            let res = try? item.resourceValues(forKeys: Set(keys))
            let isHidden = res?.isHidden ?? item.lastPathComponent.hasPrefix(".")
            if isHidden {
                hidden += 1
            } else {
                visible += 1
            }
            totalSize += Int64(res?.fileSize ?? 0)
        }
        return FolderStats(visibleCount: visible, hiddenCount: hidden, totalSizeBytes: totalSize)
    }
}

// MARK: - Folder Info View

struct FolderInfoView: View {
    let path: String
    @State private var stats: FolderStats?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let stats {
                infoGrid(stats: stats)
            } else {
                HStack {
                    ProgressView().scaleEffect(0.5)
                    Text("Loading…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: path) { await loadStats() }
    }

    @ViewBuilder
    private func infoGrid(stats: FolderStats) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            row(
                icon: "doc.fill",
                label: "Items",
                value: "\(stats.visibleCount)")
            if stats.hiddenCount > 0 {
                row(
                    icon: "eye.slash",
                    label: "Hidden",
                    value: "\(stats.hiddenCount)")
            }
            row(
                icon: "internaldrive",
                label: "Size",
                value: stats.formattedSize)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func row(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }

    private func loadStats() async {
        let p = path
        let result = await Task.detached(priority: .utility) {
            FolderStats.compute(at: p)
        }.value
        stats = result
    }
}
