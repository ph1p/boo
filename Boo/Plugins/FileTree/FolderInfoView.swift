import SwiftUI

// MARK: - Folder Stats

struct FolderStats {
    let visibleCount: Int
    let hiddenCount: Int
    let subdirCount: Int
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
        else { return FolderStats(visibleCount: 0, hiddenCount: 0, subdirCount: 0, totalSizeBytes: 0) }

        var visible = 0
        var hidden = 0
        var subdirs = 0
        var totalSize: Int64 = 0

        for item in items {
            let res = try? item.resourceValues(forKeys: Set(keys))
            let isHidden = res?.isHidden ?? item.lastPathComponent.hasPrefix(".")
            let isDir = res?.isDirectory ?? false
            if isHidden {
                hidden += 1
            } else {
                visible += 1
                if isDir { subdirs += 1 }
            }
            totalSize += Int64(res?.fileSize ?? 0)
        }
        return FolderStats(visibleCount: visible, hiddenCount: hidden, subdirCount: subdirs, totalSizeBytes: totalSize)
    }
}

// MARK: - Folder Info View

struct FolderInfoView: View {
    let path: String
    let fontScale: SidebarFontScale
    let theme: ThemeSnapshot

    @State private var stats: FolderStats?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let stats {
                infoGrid(stats: stats)
            } else {
                loadingRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: path) {
            stats = nil
            await loadStats()
        }
    }

    // MARK: - Loading

    private var loadingRow: some View {
        HStack(spacing: 5) {
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 14, height: 14)
            Text("Loading…")
                .font(fontScale.font(.base))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Info Grid

    @ViewBuilder
    private func infoGrid(stats: FolderStats) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            row(
                icon: "doc.fill",
                label: "Files",
                value: "\(stats.visibleCount - stats.subdirCount)")
            if stats.subdirCount > 0 {
                row(
                    icon: "folder.fill",
                    label: "Folders",
                    value: "\(stats.subdirCount)")
            }
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
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    // MARK: - Subviews

    @ViewBuilder
    private func row(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(fontScale.font(.sm))
                .foregroundColor(Color(theme.chromeMuted))
                .frame(width: 14)
            Text(label)
                .font(fontScale.font(.base))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(fontScale.font(.base, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Data

    private func loadStats() async {
        let p = path
        let result = await Task.detached(priority: .utility) {
            FolderStats.compute(at: p)
        }.value
        stats = result
    }
}
