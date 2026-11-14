import SwiftUI

/// Sidebar panel of the System plugin: one tile per metric, with a live graph
/// for CPU, memory and network. A tile that has a matching shell command runs
/// it in the terminal on click.
struct SystemInfoPanelView: View {
    @ObservedObject var model: SystemInfoModel
    let theme: TerminalTheme
    let fontScale: SidebarFontScale
    /// Runs a shell command in the active terminal.
    let run: (String) -> Void

    private var t: Tokens { Tokens(theme: theme) }

    var body: some View {
        let state = model.state
        VStack(spacing: 6) {
            cpuTile(state)
            memoryTile(state)
            networkTile(state)
            diskTile(state)
            if let battery = state.battery {
                batteryTile(battery)
            }
            tile(
                icon: "clock", title: "Uptime", value: SystemInfoFormat.uptime(state.uptimeSeconds),
                command: TileCommand(label: "uptime", command: "uptime")
            ) { EmptyView() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .onAppear { model.panelAppeared() }
        .onDisappear { model.panelDisappeared() }
    }

    // MARK: - Tiles

    private func cpuTile(_ state: SystemInfoState) -> some View {
        tile(
            icon: "cpu", title: "CPU", value: SystemInfoFormat.percent(state.cpuUsage),
            valueColor: alertColor(for: state.cpuUsage),
            detail: String(format: "Load %.2f", state.loadAverage),
            command: TileCommand(label: "top", command: "top -l 1 -n 10 -stats pid,command,cpu,mem")
        ) {
            Sparkline(series: [.init(values: state.cpuHistory, color: levelColor(for: state.cpuUsage))], theme: theme)
        }
    }

    private func memoryTile(_ state: SystemInfoState) -> some View {
        tile(
            icon: "memorychip", title: "Memory",
            value: String(
                format: "%@ / %.0f GB", SystemInfoFormat.gigabytes(state.memoryUsedGB, unit: false),
                state.memoryTotalGB),
            valueColor: alertColor(for: state.memoryUsage),
            detail: "\(SystemInfoFormat.percent(state.memoryUsage)) used"
        ) {
            Sparkline(
                series: [.init(values: state.memoryHistory, color: levelColor(for: state.memoryUsage))], theme: theme)
        }
    }

    private func networkTile(_ state: SystemInfoState) -> some View {
        // Both lines share one scale so they compare; the floor keeps idle noise flat.
        let peak = max((state.netInHistory + state.netOutHistory).max() ?? 0, 16 * 1024)
        return tile(
            icon: "network", title: "Network", value: "",
            command: TileCommand(label: "netstat", command: "netstat -ib")
        ) {
            Sparkline(
                series: [
                    .init(values: state.netOutHistory.map { $0 / peak }, color: t.textSecondary, filled: false),
                    .init(values: state.netInHistory.map { $0 / peak }, color: t.accent)
                ], theme: theme)
            HStack(spacing: 10) {
                rateLabel(icon: "arrow.down", rate: state.netRateIn, color: t.accent)
                rateLabel(icon: "arrow.up", rate: state.netRateOut, color: t.textSecondary)
                Spacer(minLength: 0)
            }
        }
        .accessibilityLabel(
            "Network, down \(SystemInfoFormat.rate(state.netRateIn)), up \(SystemInfoFormat.rate(state.netRateOut))")
    }

    private func diskTile(_ state: SystemInfoState) -> some View {
        tile(
            icon: "internaldrive", title: "Disk",
            value: "\(SystemInfoFormat.gigabytes(state.diskFreeGB)) free",
            valueColor: alertColor(for: state.diskUsage),
            detail: "\(SystemInfoFormat.percent(state.diskUsage)) used",
            command: TileCommand(label: "df -h", command: "df -h")
        ) {
            UsageBar(ratio: state.diskUsage, color: levelColor(for: state.diskUsage), track: t.controlFill)
        }
    }

    private func batteryTile(_ battery: BatteryInfo) -> some View {
        let color: Color =
            battery.isCharging ? t.success : battery.level < 0.15 ? t.error : battery.level < 0.3 ? t.warning : t.accent
        return tile(
            icon: SystemInfoFormat.batteryIcon(battery), title: "Battery",
            value: SystemInfoFormat.percent(battery.level),
            valueColor: !battery.isCharging && battery.level < 0.3 ? color : nil,
            detail: battery.isCharging ? "Charging" : (battery.isPluggedIn ? "Plugged in" : "On battery")
        ) {
            UsageBar(ratio: battery.level, color: color, track: t.controlFill)
        }
    }

    private func tile<Chart: View>(
        icon: String, title: String, value: String, valueColor: Color? = nil, detail: String? = nil,
        command: TileCommand? = nil, @ViewBuilder chart: () -> Chart
    ) -> some View {
        MetricTile(
            icon: icon, title: title, value: value, valueColor: valueColor, detail: detail, command: command,
            theme: theme, fontScale: fontScale, run: run, chart: chart())
    }

    private func rateLabel(icon: String, rate: UInt64, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(fontScale.font(.xs).weight(.semibold))
                .foregroundStyle(color)
            Text(SystemInfoFormat.rate(rate))
                .font(fontScale.font(.sm).monospacedDigit())
                .foregroundStyle(t.text)
                .lineLimit(1)
        }
    }

    // MARK: - Colors

    /// Graph and bar color: the accent, shifting to warning and error as usage climbs.
    private func levelColor(for usage: Double) -> Color {
        alertColor(for: usage) ?? t.accent
    }

    /// Warning or error color once usage is high, else `nil` (normal text).
    private func alertColor(for usage: Double) -> Color? {
        if usage > 0.85 { return t.error }
        if usage > 0.7 { return t.warning }
        return nil
    }
}

// MARK: - Formatting

enum SystemInfoFormat {
    static func percent(_ ratio: Double) -> String {
        "\(Int((min(1, max(0, ratio)) * 100).rounded()))%"
    }

    static func gigabytes(_ gb: Double, unit: Bool = true) -> String {
        let number = String(format: gb >= 100 ? "%.0f" : "%.1f", gb)
        return unit ? "\(number) GB" : number
    }

    static func rate(_ bytesPerSecond: UInt64) -> String {
        if bytesPerSecond < 1024 { return "\(bytesPerSecond) B/s" }
        let kb = Double(bytesPerSecond) / 1024
        if kb < 1024 { return String(format: kb < 10 ? "%.1f KB/s" : "%.0f KB/s", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB/s", mb) }
        return String(format: "%.1f GB/s", mb / 1024)
    }

    static func uptime(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let mins = (total % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h \(mins)m" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }

    static func batteryIcon(_ battery: BatteryInfo) -> String {
        if battery.isCharging { return "battery.100.bolt" }
        switch battery.level {
        case ..<0.125: return "battery.0"
        case ..<0.375: return "battery.25"
        case ..<0.625: return "battery.50"
        case ..<0.875: return "battery.75"
        default: return "battery.100"
        }
    }
}

// MARK: - Tile

private struct TileCommand {
    /// Short name shown on hover.
    let label: String
    let command: String
}

private struct MetricTile<Chart: View>: View {
    let icon: String
    let title: String
    let value: String
    let valueColor: Color?
    let detail: String?
    let command: TileCommand?
    let theme: TerminalTheme
    let fontScale: SidebarFontScale
    let run: (String) -> Void
    let chart: Chart

    @State private var isHovered = false

    private var t: Tokens { Tokens(theme: theme) }

    var body: some View {
        if let command {
            Button {
                run(command.command)
            } label: {
                content
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .help("Run \(command.command) in the terminal")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenLabel)
            .accessibilityHint("Runs \(command.label) in the terminal")
            .accessibilityAddTraits(.isButton)
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spokenLabel)
        }
    }

    private var spokenLabel: String {
        [title, value, detail ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(fontScale.font(.sm))
                    .foregroundStyle(t.textSecondary)
                    .frame(width: fontScale.size(.base) + 4)
                Text(title)
                    .font(fontScale.font(.sm))
                    .foregroundStyle(t.textSecondary)
                    .lineLimit(1)
                if let command {
                    // Always laid out, so hovering does not shift the row.
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.right")
                        Text(command.label)
                    }
                    .font(fontScale.font(.xs, design: .monospaced))
                    .foregroundStyle(t.textTertiary)
                    .lineLimit(1)
                    .opacity(isHovered ? 1 : 0)
                }
                Spacer(minLength: 4)
                Text(value)
                    .font(fontScale.font(.base).monospacedDigit().weight(.medium))
                    .foregroundStyle(valueColor ?? t.text)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            chart
            if let detail {
                Text(detail)
                    .font(fontScale.font(.xs).monospacedDigit())
                    .foregroundStyle(t.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(t.cardBg)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovered ? t.hoverFill : Color.clear))
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Charts

/// Line graph of recent samples, newest at the right edge. Values are 0...1.
private struct Sparkline: View {
    struct Series {
        let values: [Double]
        let color: Color
        var filled = true
    }

    let series: [Series]
    let theme: TerminalTheme

    var body: some View {
        ZStack {
            ForEach(series.indices, id: \.self) { index in
                let line = series[index]
                if line.filled {
                    SparklineShape(values: line.values, closed: true)
                        .fill(
                            LinearGradient(
                                colors: [line.color.opacity(0.3), line.color.opacity(0.03)],
                                startPoint: .top, endPoint: .bottom))
                }
                SparklineShape(values: line.values, closed: false)
                    .stroke(line.color, style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
            }
        }
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background(alignment: .bottom) {
            Rectangle()
                .fill(Tokens(theme: theme).separator)
                .frame(height: 1)
        }
        .accessibilityHidden(true)
    }
}

private struct SparklineShape: Shape {
    let values: [Double]
    let closed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let slots = SystemInfoModel.historyLength
        guard values.count > 1, slots > 1 else { return path }
        let step = rect.width / CGFloat(slots - 1)
        let startX = rect.maxX - step * CGFloat(values.count - 1)
        let points = values.enumerated().map { index, value in
            CGPoint(
                x: startX + step * CGFloat(index),
                y: rect.maxY - CGFloat(min(1, max(0, value))) * rect.height)
        }
        path.addLines(points)
        if closed {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: startX, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

private struct UsageBar: View {
    let ratio: Double
    let color: Color
    let track: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule()
                    .fill(color)
                    .frame(width: geo.size.width * CGFloat(min(1, max(0, ratio))))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}
