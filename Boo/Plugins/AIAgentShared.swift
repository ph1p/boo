import SwiftUI

// MARK: - AI Agent Shared Module
//
// Shared types, utilities, and SwiftUI components for AI agent plugins
// (ClaudeCode, Codex, OpenCode). Eliminates code duplication across plugins.
//
// Types:
//   - AgentConfigScope: enum for project vs global config scope
//   - AgentConfigFile: config file entry with path, icon, scope
//   - AgentSkillEntry: skill with name, description, path
//   - AgentDiffStatEntry: git diff stat (insertions/deletions per file)
//
// Utilities:
//   - formatAgentRuntime(_:): "2h 30m" style runtime formatting
//   - formatAgentRelativeDate(_:): "2h ago", "3d ago" relative dates
//   - findAgentProjectRoot(from:markers:): walk up to find project root
//   - checkAgentConfigFile(...): check existence and add to config list
//   - parseAgentSkillDescription(at:): extract description from SKILL.md YAML
//   - detectAgentDiffStats(repoRoot:): run `git diff --numstat HEAD`
//
// SwiftUI Components:
//   - AgentCollapsibleHeader: expandable section header with chevron
//   - AgentStaticHeader: non-expandable section header
//   - AgentConfigRow: config file row with scope badge and context menu
//   - AgentDiffRow: changed file row with +/- stats and context menu

// MARK: - Shared Types

/// Scope of a config file (project-local or global).
enum AgentConfigScope: String {
    case project
    case global
}

/// A config file entry for AI agent plugins.
struct AgentConfigFile: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let icon: String
    let scope: AgentConfigScope
}

/// A skill entry for AI agent plugins.
struct AgentSkillEntry: Identifiable {
    let id = UUID()
    let name: String
    let description: String
    let path: String
}

/// Git diff stat entry for changed files.
struct AgentDiffStatEntry: Identifiable {
    let id = UUID()
    let path: String
    let insertions: Int
    let deletions: Int
    let fullPath: String
}

// MARK: - Shared Utilities

/// Format runtime duration as human-readable string.
func formatAgentRuntime(_ seconds: TimeInterval) -> String {
    let totalSeconds = Int(seconds)
    let hours = totalSeconds / 3600
    let mins = (totalSeconds % 3600) / 60
    if hours > 0 {
        return "\(hours)h \(mins)m"
    } else if mins > 0 {
        return "\(mins)m"
    } else {
        return "<1m"
    }
}

/// Format date as relative string (e.g., "2h ago", "3d ago").
func formatAgentRelativeDate(_ date: Date) -> String {
    let interval = Date().timeIntervalSince(date)
    if interval < 60 {
        return "just now"
    } else if interval < 3600 {
        return "\(Int(interval / 60))m ago"
    } else if interval < 86400 {
        return "\(Int(interval / 3600))h ago"
    } else if interval < 604_800 {
        return "\(Int(interval / 86400))d ago"
    } else {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}

/// Find project root by walking up from path looking for marker files/dirs.
func findAgentProjectRoot(from path: String, markers: [String]) -> String? {
    let fm = FileManager.default
    var dir = path
    for _ in 0..<20 {
        for marker in markers {
            let candidate = (dir as NSString).appendingPathComponent(marker)
            if fm.fileExists(atPath: candidate) {
                return dir
            }
        }
        let parent = (dir as NSString).deletingLastPathComponent
        if parent == dir { break }
        dir = parent
    }
    return nil
}

/// Check if file exists and add to config list if so.
func checkAgentConfigFile(
    fm: FileManager, root: String, rel: String, name: String,
    icon: String, scope: AgentConfigScope, into files: inout [AgentConfigFile]
) {
    let fullPath = (root as NSString).appendingPathComponent(rel)
    if fm.fileExists(atPath: fullPath) {
        if !files.contains(where: { $0.path == fullPath }) {
            files.append(AgentConfigFile(name: name, path: fullPath, icon: icon, scope: scope))
        }
    }
}

/// Parse skill description from YAML frontmatter in SKILL.md.
func parseAgentSkillDescription(at path: String) -> String {
    guard let data = FileManager.default.contents(atPath: path),
        let content = String(data: data, encoding: .utf8)
    else { return "" }

    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
    var inFrontmatter = false
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed == "---" {
            if inFrontmatter { break }
            inFrontmatter = true
            continue
        }
        if inFrontmatter && trimmed.hasPrefix("description:") {
            return String(trimmed.dropFirst("description:".count)).trimmingCharacters(in: .whitespaces)
        }
    }
    return ""
}

/// Detect git diff stats for changed files in repo.
func detectAgentDiffStats(repoRoot: String) -> [AgentDiffStatEntry] {
    let task = Process()
    task.launchPath = "/usr/bin/git"
    task.arguments = ["-C", repoRoot, "diff", "--numstat", "HEAD"]
    task.standardError = FileHandle.nullDevice

    let pipe = Pipe()
    task.standardOutput = pipe

    do {
        try task.run()
    } catch {
        return []
    }
    task.waitUntilExit()
    guard task.terminationStatus == 0 else { return [] }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else { return [] }

    return output.split(separator: "\n").compactMap { line in
        let parts = line.split(separator: "\t", maxSplits: 2)
        guard parts.count == 3 else { return nil }
        let insertions = Int(parts[0]) ?? 0
        let deletions = Int(parts[1]) ?? 0
        let filePath = String(parts[2])
        let fullPath = (repoRoot as NSString).appendingPathComponent(filePath)
        return AgentDiffStatEntry(
            path: filePath,
            insertions: insertions,
            deletions: deletions,
            fullPath: fullPath
        )
    }
}

// MARK: - Shared SwiftUI Components

/// Collapsible section header for agent detail views.
struct AgentCollapsibleHeader: View {
    let title: String
    let icon: String
    let count: Int
    @Binding var isExpanded: Bool
    var trailing: String?
    let fontScale: SidebarFontScale
    let textColor: Color
    let mutedColor: Color

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(mutedColor)
                    .frame(width: 8)

                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundColor(mutedColor)

                Text("\(title) (\(count))")
                    .font(fontScale.font(.sm).weight(.semibold))
                    .foregroundColor(textColor)

                Spacer()

                if let trailing = trailing {
                    Text(trailing)
                        .font(fontScale.font(.xs, design: .monospaced))
                        .foregroundColor(mutedColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Static section header for agent detail views.
struct AgentStaticHeader: View {
    let title: String
    let icon: String
    let count: Int
    let fontScale: SidebarFontScale
    let textColor: Color
    let mutedColor: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundColor(mutedColor)

            Text("\(title) (\(count))")
                .font(fontScale.font(.sm).weight(.semibold))
                .foregroundColor(textColor)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// Config file row for agent detail views.
struct AgentConfigRow: View {
    let file: AgentConfigFile
    let fontScale: SidebarFontScale
    let textColor: Color
    let mutedColor: Color
    let accentColor: Color
    let isHovered: Bool
    let onFileClicked: (String) -> Void
    let onCopyPath: (String) -> Void
    let onReferenceInAI: ((String) -> Void)?

    var body: some View {
        Button(action: { onFileClicked(file.path) }) {
            HStack(spacing: 6) {
                Image(systemName: file.icon)
                    .font(fontScale.font(.sm))
                    .foregroundColor(file.scope == .global ? mutedColor : accentColor)
                    .frame(width: 14)

                Text(file.name)
                    .font(fontScale.font(.base))
                    .foregroundColor(textColor)
                    .lineLimit(1)

                Spacer()

                if file.scope == .global {
                    Text("global")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(mutedColor.opacity(0.7))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(mutedColor.opacity(0.1))
                        )
                }
            }
            .frame(height: 24)
            .padding(.horizontal, 12)
            .padding(.leading, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isHovered ? mutedColor.opacity(0.08) : Color.clear)
        .contextMenu {
            Button("Open in Editor") { onFileClicked(file.path) }
            if let onRef = onReferenceInAI {
                Button("Reference in AI (@)") { onRef(file.path) }
            }
            Divider()
            Button("Copy Path") { onCopyPath(file.path) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(file.path, inFileViewerRootedAtPath: "")
            }
        }
    }
}

/// Diff stat file row for agent detail views.
struct AgentDiffRow: View {
    let entry: AgentDiffStatEntry
    let fontScale: SidebarFontScale
    let textColor: Color
    let onFileClicked: (String) -> Void
    let onCopyPath: (String) -> Void
    let onReferenceInAI: ((String) -> Void)?

    var body: some View {
        Button(action: { onFileClicked(entry.fullPath) }) {
            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    Text("+\(entry.insertions)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Color(nsColor: .systemGreen))
                    Text("-\(entry.deletions)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Color(nsColor: .systemRed))
                }
                .frame(width: 56, alignment: .leading)

                Text(entry.path)
                    .font(fontScale.font(.base))
                    .foregroundColor(textColor)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()
            }
            .frame(height: 24)
            .padding(.horizontal, 12)
            .padding(.leading, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let onRef = onReferenceInAI {
                Button("Reference in AI (@)") { onRef(entry.path) }
            }
            Button("Open in Editor") { onFileClicked(entry.fullPath) }
            Divider()
            Button("Copy Path") { onCopyPath(entry.path) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(entry.fullPath, inFileViewerRootedAtPath: "")
            }
        }
        .accessibilityLabel("\(entry.path): \(entry.insertions) insertions, \(entry.deletions) deletions")
    }
}
