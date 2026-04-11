// PiScope — macOS menu bar app to monitor pi coding agent sessions
// Single-file SwiftUI app. Build: swiftc -parse-as-library -framework SwiftUI -framework AppKit -o PiScope PiScopeApp.swift

import SwiftUI
import AppKit

// MARK: - App Entry Point

@main
struct PiScopeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var statsModel = StatsModel()
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // hide from Dock

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "π …"
            button.action = #selector(togglePopover)
            button.target = self
        }

        let popover = NSPopover()
        popover.contentSize = NSSize(width: 900, height: 700)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ContentView(model: statsModel, onReload: { [weak self] in self?.refresh() }))
        self.popover = popover

        // Initial load then every 30s
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            let stats = loadAppStats()
            DispatchQueue.main.async {
                guard let self else { return }
                self.statsModel.stats = stats
                let todayCost = stats.filteredSessions(for: .today).reduce(0.0) { $0 + $1.totalCost }
                let label = String(format: "π $%.2f", todayCost)
                self.statusItem.button?.title = label
            }
        }
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - Observable Stats Model

class StatsModel: ObservableObject {
    @Published var stats = AppStats()
}

// MARK: - Data Models

struct SessionData: Identifiable {
    let id: String
    let cwd: String
    let timestamp: Date
    var name: String
    var totalCost: Double
    var totalTokens: Int
    var messageCount: Int      // assistant messages
    var userMessageCount: Int   // user messages
    var toolCallCount: Int
    var hasError: Bool
    var primaryModel: String
    var lastTimestamp: Date
    var rawInputTokens: Int
    var cacheReadTokens: Int
    var cacheWriteTokens: Int
    var cacheReadCost: Double
    var filePath: URL

    var project: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }
}

struct AppStats {
    var sessions: [SessionData] = []  // all sessions, sorted by most recent
    var totalSessions: Int = 0
    // Today


    func filteredSessions(for range: TimeRange) -> [SessionData] {
        sessions.filter { range.contains($0.timestamp) }
    }
}

// MARK: - JSONL Parser

func loadAppStats() -> AppStats {
    let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".pi/agent/sessions")

    guard let projectDirs = try? FileManager.default.contentsOfDirectory(
        at: sessionsDir, includingPropertiesForKeys: nil
    ) else { return AppStats() }

    var sessions: [SessionData] = []

    let isoFull = ISO8601DateFormatter()
    isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let isoBasic = ISO8601DateFormatter()

    func parseDate(_ s: String) -> Date? {
        isoFull.date(from: s) ?? isoBasic.date(from: s)
    }

    for projectDir in projectDirs {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: projectDir, includingPropertiesForKeys: nil
        ) else { continue }

        for file in files where file.pathExtension == "jsonl" {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let lines = content.split(separator: "\n", omittingEmptySubsequences: true)

            var sessionId = ""
            var sessionCwd = ""
            var sessionTimestamp: Date?
            var sessionName = ""
            var firstUserMessage = ""
            var totalCost = 0.0
            var totalTokens = 0
            var messageCount = 0
            var userMessageCount = 0
            var hasError = false
            var modelCostMap: [String: Double] = [:]
            var toolCallCount = 0
            var rawInputTokens = 0
            var cacheReadTokens = 0
            var cacheWriteTokens = 0
            var cacheReadCost = 0.0
            var lastTimestamp: Date?

            for line in lines {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                let type = obj["type"] as? String ?? ""
                let tsStr = obj["timestamp"] as? String ?? ""
                let ts = tsStr.isEmpty ? nil : parseDate(tsStr)
                if let ts { lastTimestamp = ts }

                switch type {
                case "session":
                    sessionId = obj["id"] as? String ?? ""
                    sessionCwd = obj["cwd"] as? String ?? ""
                    sessionTimestamp = ts

                case "session_info":
                    sessionName = obj["name"] as? String ?? ""

                case "message":
                    let msg = obj["message"] as? [String: Any] ?? [:]
                    let role = msg["role"] as? String ?? ""

                    if role == "user" {
                        userMessageCount += 1
                        if firstUserMessage.isEmpty {
                            if let content = msg["content"] as? [[String: Any]] {
                                for part in content {
                                    if part["type"] as? String == "text",
                                       let text = part["text"] as? String {
                                        firstUserMessage = String(text.prefix(60))
                                        break
                                    }
                                }
                            }
                        }
                    }

                    if role == "assistant" {
                        messageCount += 1
                        var msgCost = 0.0
                        if let usage = msg["usage"] as? [String: Any],
                           let costDict = usage["cost"] as? [String: Any],
                           let costTotal = costDict["total"] as? Double {
                            msgCost = costTotal
                            totalCost += msgCost
                        }
                        if let usage = msg["usage"] as? [String: Any],
                           let tokens = usage["totalTokens"] as? Int {
                            totalTokens += tokens
                        }
                        if let stopReason = msg["stopReason"] as? String, stopReason == "error" {
                            hasError = true
                        }
                        if let usage = msg["usage"] as? [String: Any] {
                            rawInputTokens  += usage["input"]      as? Int ?? 0
                            cacheReadTokens += usage["cacheRead"]  as? Int ?? 0
                            cacheWriteTokens += usage["cacheWrite"] as? Int ?? 0
                        }
                        if let costDict = (msg["usage"] as? [String: Any])?["cost"] as? [String: Any] {
                            cacheReadCost += costDict["cacheRead"] as? Double ?? 0
                        }
                        if let model = msg["model"] as? String {
                            modelCostMap[model, default: 0] += msgCost > 0 ? msgCost : 1
                        }
                        if let content = msg["content"] as? [[String: Any]] {
                            toolCallCount += content.filter { $0["type"] as? String == "toolCall" }.count
                        }
                    }

                default:
                    break
                }
            }

            guard let sessionTimestamp, !sessionId.isEmpty else { continue }

            let displayName: String
            if !sessionName.isEmpty {
                displayName = sessionName
            } else if !firstUserMessage.isEmpty {
                displayName = firstUserMessage
            } else {
                displayName = "Untitled"
            }

            let primaryModel = modelCostMap.max(by: { $0.value < $1.value })?.key ?? ""

            sessions.append(SessionData(
                id: sessionId,
                cwd: sessionCwd,
                timestamp: sessionTimestamp,
                name: displayName,
                totalCost: totalCost,
                totalTokens: totalTokens,
                messageCount: messageCount,
                userMessageCount: userMessageCount,
                toolCallCount: toolCallCount,
                hasError: hasError,
                primaryModel: primaryModel,
                lastTimestamp: lastTimestamp ?? sessionTimestamp,
                rawInputTokens: rawInputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheWriteTokens: cacheWriteTokens,
                cacheReadCost: cacheReadCost,
                filePath: file
            ))
        }
    }

    sessions.sort { $0.timestamp > $1.timestamp }

    var stats = AppStats()
    stats.sessions = sessions
    stats.totalSessions = sessions.count



    return stats
}

// MARK: - Time Range

enum TimeRange: String, CaseIterable {
    case today    = "Today"
    case thisWeek = "This Week"
    case last30d  = "Last 30d"
    case allTime  = "All Time"

    var displayName: String {
        switch self {
        case .today:    return "Today"
        case .thisWeek: return "This Week"
        case .last30d:  return "Last 30 Days"
        case .allTime:  return "All Time"
        }
    }

    func contains(_ date: Date) -> Bool {
        let cal = Calendar.current
        let now = Date()
        switch self {
        case .today:    return cal.isDateInToday(date)
        case .thisWeek: return cal.isDate(date, equalTo: now, toGranularity: .weekOfYear)
        case .last30d:  return date >= cal.date(byAdding: .day, value: -30, to: now)!
        case .allTime:  return true
        }
    }
}

// MARK: - Formatters

func fmtCost(_ v: Double) -> String { String(format: "$%.2f", v) }
func fmtTokens(_ v: Int) -> String {
    switch v {
    case 0..<1_000:         return "\(v)"
    case 1_000..<10_000:    return String(format: "%.1fk", Double(v) / 1_000)
    case 10_000..<1_000_000: return String(format: "%.0fk", Double(v) / 1_000)
    case 1_000_000..<10_000_000: return String(format: "%.2fM", Double(v) / 1_000_000)
    default:                return String(format: "%.1fM", Double(v) / 1_000_000)
    }
}
func timeAgo(from date: Date) -> String {
    let secs = Int(Date().timeIntervalSince(date))
    if secs < 60 { return "\(secs)s ago" }
    if secs < 3600 { return "\(secs / 60)m ago" }
    if secs < 86400 { return "\(secs / 3600)h ago" }
    return "\(secs / 86400)d ago"
}

func fmtDuration(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    return String(format: "%dh%02dm", seconds / 3600, (seconds % 3600) / 60)
}
let shortDateFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MMM d HH:mm"
    return f
}()

// MARK: - Root Content View

struct ContentView: View {
    @ObservedObject var model: StatsModel
    let onReload: () -> Void
    @State private var selectedRange: TimeRange = .today

    var body: some View {
        VStack(spacing: 0) {
            // Top bar: time range selector (centered) + buttons (right)
            HStack {
                Spacer()
                Picker("", selection: $selectedRange) {
                    ForEach(TimeRange.allCases, id: \.self) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer()
                Button("Reload") { onReload() }
                    .buttonStyle(.bordered)
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)

            Divider()

            HStack(spacing: 0) {
                LeftColumnView(stats: model.stats, selectedRange: $selectedRange)
                    .frame(width: 440)
                Divider()
                RightColumnView(stats: model.stats, selectedRange: selectedRange, onReload: onReload)
                    .frame(width: 420)
            }
        }
        .frame(width: 900, height: 700)
    }
}

// MARK: - Left Column

struct LeftColumnView: View {
    let stats: AppStats
    @Binding var selectedRange: TimeRange

    var sparklineBuckets: [(label: String, cost: Double)] {
        let cal = Calendar.current
        let now = Date()
        let sessions = stats.filteredSessions(for: selectedRange)

        switch selectedRange {
        case .today:
            let dayStart = cal.startOfDay(for: now)
            return (0..<24).map { h in
                let start = cal.date(byAdding: .hour, value: h, to: dayStart)!
                let end   = cal.date(byAdding: .hour, value: 1, to: start)!
                let cost  = sessions.filter { $0.timestamp >= start && $0.timestamp < end }
                                    .reduce(0.0) { $0 + $1.totalCost }
                return (label: String(format: "%02d:00", h), cost: cost)
            }
        case .thisWeek:
            let weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
            return (0..<7).map { d in
                let start = cal.date(byAdding: .day, value: d, to: weekStart)!
                let end   = cal.date(byAdding: .day, value: 1, to: start)!
                let cost  = sessions.filter { $0.timestamp >= start && $0.timestamp < end }
                                    .reduce(0.0) { $0 + $1.totalCost }
                let fmt = DateFormatter(); fmt.dateFormat = "EEE"
                return (label: fmt.string(from: start), cost: cost)
            }
        case .last30d:
            let rangeStart = cal.date(byAdding: .day, value: -29, to: cal.startOfDay(for: now))!
            return (0..<30).map { d in
                let start = cal.date(byAdding: .day, value: d, to: rangeStart)!
                let end   = cal.date(byAdding: .day, value: 1, to: start)!
                let cost  = sessions.filter { $0.timestamp >= start && $0.timestamp < end }
                                    .reduce(0.0) { $0 + $1.totalCost }
                let fmt = DateFormatter(); fmt.dateFormat = "MMM d"
                return (label: fmt.string(from: start), cost: cost)
            }
        case .allTime:
            return (0..<12).map { m in
                let monthDate = cal.date(byAdding: .month, value: -(11 - m), to: now)!
                let comps     = cal.dateComponents([.year, .month], from: monthDate)
                let start     = cal.date(from: comps)!
                let end       = cal.date(byAdding: .month, value: 1, to: start)!
                let cost      = stats.sessions.filter { $0.timestamp >= start && $0.timestamp < end }
                                              .reduce(0.0) { $0 + $1.totalCost }
                let fmt = DateFormatter(); fmt.dateFormat = "MMM"
                return (label: fmt.string(from: start), cost: cost)
            }
        }
    }

    var rangeStats: (cost: Double, tokens: Int, models: Int, toolCalls: Int,
                     messages: Int, userMessages: Int,
                     hitRatio: Double, savings: Double,
                     modelBreakdown: [(model: String, fraction: Double, cost: Double)],
                     topProjects: [(project: String, cost: Double)]) {
        let sessions = stats.filteredSessions(for: selectedRange)
        let cost = sessions.reduce(0.0) { $0 + $1.totalCost }
        let tokens = sessions.reduce(0) { $0 + $1.totalTokens }
        let toolCalls    = sessions.reduce(0)   { $0 + $1.toolCallCount }
        let messages     = sessions.reduce(0)   { $0 + $1.messageCount }
        let userMessages = sessions.reduce(0)   { $0 + $1.userMessageCount }
        let cacheRead    = sessions.reduce(0)   { $0 + $1.cacheReadTokens }
        let cacheWrite   = sessions.reduce(0)   { $0 + $1.cacheWriteTokens }
        let rawInput     = sessions.reduce(0)   { $0 + $1.rawInputTokens }
        let cacheReadCost = sessions.reduce(0.0){ $0 + $1.cacheReadCost }
        let totalCtx     = rawInput + cacheRead + cacheWrite
        let hitRatio     = totalCtx > 0 ? Double(cacheRead) / Double(totalCtx) : 0.0
        // cache reads cost ~10% of input rate across all Anthropic models → 9× savings
        let savings      = cacheReadCost * 9

        var modelCost: [String: Double] = [:]
        for s in sessions where !s.primaryModel.isEmpty {
            modelCost[s.primaryModel, default: 0] += s.totalCost
        }
        let totalModelCost = modelCost.values.reduce(0, +)
        let modelBreakdown: [(model: String, fraction: Double, cost: Double)] = totalModelCost > 0
            ? modelCost.sorted { $0.value > $1.value }.prefix(3)
                .map { (model: $0.key, fraction: $0.value / totalModelCost, cost: $0.value) }
            : []

        var projectCost: [String: Double] = [:]
        for s in sessions { projectCost[s.project, default: 0] += s.totalCost }
        let topProjects = projectCost.sorted { $0.value > $1.value }.prefix(5)
            .map { (project: $0.key, cost: $0.value) }

        return (cost, tokens, modelCost.count, toolCalls, messages, userMessages, hitRatio, savings, modelBreakdown, topProjects)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {

                // 3a. Activity card
                SectionCard(title: "Activity", color: .blue) {
                    HStack(spacing: 16) {
                        StatPill(label: "sessions",   value: "\(stats.filteredSessions(for: selectedRange).count)", color: .blue)
                        StatPill(label: "messages",   value: "\(rangeStats.messages + rangeStats.userMessages)", color: .blue)
                        StatPill(label: "user msgs",  value: "\(rangeStats.userMessages)", color: .blue)
                        StatPill(label: "tool calls", value: "\(rangeStats.toolCalls)", color: .blue)
                        StatPill(label: "models",     value: "\(rangeStats.models)", color: .blue)
                        StatPill(label: "cache hits", value: String(format: "%.0f%%", rangeStats.hitRatio * 100), color: .blue)
                        Spacer()
                    }
                }

                // 3b. Cost card
                SectionCard(title: "Cost", color: .orange) {
                    HStack(spacing: 16) {
                        StatPill(label: "cost",     value: fmtCost(rangeStats.cost), color: .orange)
                        StatPill(label: "tokens",   value: fmtTokens(rangeStats.tokens), color: .orange)
                        StatPill(label: "cache savings",  value: "~" + fmtCost(rangeStats.savings), color: .orange)
                        Spacer()
                    }
                }

                // 4. Cost over time sparkline
                SectionCard(title: "Cost over time", color: .purple) {
                    SparklineView(buckets: sparklineBuckets)
                        .frame(height: 64)
                    HStack {
                        Spacer()
                        Text(fmtCost(sparklineBuckets.map(\.cost).reduce(0, +)) + " total")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // 5. Top 5 projects
                if !rangeStats.topProjects.isEmpty {
                    let maxCost = rangeStats.topProjects.first?.cost ?? 1
                    SectionCard(title: "Top \(rangeStats.topProjects.count) Projects", color: .green) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(rangeStats.topProjects, id: \.project) { entry in
                                HStack(spacing: 6) {
                                    Text(entry.project)
                                        .font(.caption)
                                        .frame(width: 130, alignment: .leading)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    GeometryReader { geo in
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(Color.green.opacity(0.7))
                                            .frame(width: geo.size.width * (entry.cost / maxCost))
                                            .frame(maxHeight: .infinity)
                                    }
                                    .frame(height: 10)
                                    Text(fmtCost(entry.cost))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 44, alignment: .trailing)
                                }
                            }
                        }
                    }
                }

                // 6. Top 3 models
                if !rangeStats.modelBreakdown.isEmpty {
                    SectionCard(title: "Top \(rangeStats.modelBreakdown.count) Models", color: .indigo) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(rangeStats.modelBreakdown, id: \.model) { entry in
                                ModelBarRow(entry: entry)
                            }
                        }
                    }
                }

                Spacer()

            }
            .padding()
        }
    }
}

struct ModelBarRow: View {
    let entry: (model: String, fraction: Double, cost: Double)
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(entry.model)
                .font(.caption)
                .frame(width: 170, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.indigo)
                    .frame(width: geo.size.width * entry.fraction)
                    .frame(maxHeight: .infinity)
            }
            .frame(height: 10)
            if hovered {
                Text(fmtCost(entry.cost))
                    .font(.caption2)
                    .foregroundStyle(.primary)
                    .frame(width: 50, alignment: .trailing)
            } else {
                Text(String(format: "%.0f%%", entry.fraction * 100))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .trailing)
            }
        }
        .onHover { hovered = $0 }
    }
}

struct SparklineView: View {
    let buckets: [(label: String, cost: Double)]
    @State private var hoveredIndex: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let i = hoveredIndex {
                HStack {
                    Text(buckets[i].label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(fmtCost(buckets[i].cost))
                        .font(.caption2)
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 16)
            } else {
                Color.clear.frame(height: 16)
            }

            GeometryReader { geo in
                let maxVal = max(buckets.map(\.cost).max() ?? 0, 0.001)
                let w = geo.size.width
                let h = geo.size.height
                let count = buckets.count
                guard count > 1 else { return AnyView(EmptyView()) }

                let points: [CGPoint] = (0..<count).map { i in
                    CGPoint(
                        x: w * CGFloat(i) / CGFloat(count - 1),
                        y: h * (1 - CGFloat(buckets[i].cost) / CGFloat(maxVal))
                    )
                }

                // Area fill path
                var area = Path()
                area.move(to: CGPoint(x: points[0].x, y: h))
                area.addLine(to: points[0])
                for i in 1..<count {
                    let prev = points[i - 1], curr = points[i]
                    let cp1 = CGPoint(x: (prev.x + curr.x) / 2, y: prev.y)
                    let cp2 = CGPoint(x: (prev.x + curr.x) / 2, y: curr.y)
                    area.addCurve(to: curr, control1: cp1, control2: cp2)
                }
                area.addLine(to: CGPoint(x: points[count - 1].x, y: h))
                area.closeSubpath()

                // Line path
                var line = Path()
                line.move(to: points[0])
                for i in 1..<count {
                    let prev = points[i - 1], curr = points[i]
                    let cp1 = CGPoint(x: (prev.x + curr.x) / 2, y: prev.y)
                    let cp2 = CGPoint(x: (prev.x + curr.x) / 2, y: curr.y)
                    line.addCurve(to: curr, control1: cp1, control2: cp2)
                }

                return AnyView(
                    ZStack(alignment: .bottom) {
                        // Area
                        area.fill(
                            LinearGradient(
                                colors: [Color.purple.opacity(0.12), Color.purple.opacity(0.01)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        // Line
                        line.stroke(Color.purple, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

                        // Hover dot
                        if let i = hoveredIndex {
                            Circle()
                                .fill(Color.purple)
                                .frame(width: 6, height: 6)
                                .position(x: points[i].x, y: points[i].y)
                        }

                        // Invisible hit zones
                        HStack(spacing: 0) {
                            ForEach(0..<count, id: \.self) { i in
                                Rectangle()
                                    .fill(Color.clear)
                                    .contentShape(Rectangle())
                                    .onHover { inside in hoveredIndex = inside ? i : nil }
                            }
                        }
                    }
                )
            }
        }
    }
}

struct SectionCard<Content: View>: View {
    let title: String
    var color: Color = .primary
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: 3, height: 11)
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
            }
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.05))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(color.opacity(0.15), lineWidth: 1)
        )
    }
}

struct StatPill: View {
    let label: String
    let value: String
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Right Column

struct RightColumnView: View {
    let stats: AppStats
    let selectedRange: TimeRange
    let onReload: () -> Void
    @State private var sortOrder: SortOrder = .recent

    enum SortOrder { case recent, cost, duration, project }

    var sortedSessions: [SessionData] {
        let filtered = stats.filteredSessions(for: selectedRange)
        switch sortOrder {
        case .recent:   return filtered
        case .cost:     return filtered.sorted { $0.totalCost > $1.totalCost }
        case .duration: return filtered.sorted {
            $0.lastTimestamp.timeIntervalSince($0.timestamp) >
            $1.lastTimestamp.timeIntervalSince($1.timestamp) }
        case .project:  return filtered.sorted { $0.project.localizedCompare($1.project) == .orderedAscending }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                let count = stats.filteredSessions(for: selectedRange).count
                Text(count == stats.totalSessions
                     ? "all \(count) sessions"
                     : "\(count) of \(stats.totalSessions) sessions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Sort:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SortButton(label: "Recent",   active: sortOrder == .recent)   { sortOrder = .recent }
                SortButton(label: "Cost",     active: sortOrder == .cost)     { sortOrder = .cost }
                SortButton(label: "Duration", active: sortOrder == .duration) { sortOrder = .duration }
                SortButton(label: "Project",  active: sortOrder == .project)  { sortOrder = .project }
            }
            .padding(.horizontal)
            .padding(.top, 12)

            ScrollView {
                LazyVStack(spacing: 6) {
                    let maxCost = sortedSessions.map(\.totalCost).max() ?? 1
                    ForEach(sortedSessions) { session in
                        let fraction = maxCost > 0 ? session.totalCost / maxCost : 0
                        SessionRowView(session: session, costFraction: fraction, onDelete: onReload)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
    }
}

struct SortButton: View {
    let label: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .fontWeight(active ? .semibold : .regular)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(active ? Color.accentColor.opacity(0.15) : Color.clear)
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }
}

struct MetricCell: View {
    let value: String
    let label: String
    let showLabel: Bool
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
            if showLabel {
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(minWidth: 36, alignment: .trailing)
    }
}

struct SessionRowView: View {
    let session: SessionData
    let costFraction: Double   // 0.0–1.0 relative to max in current list
    let onDelete: () -> Void
    @State private var hovered = false

    /// Color that shifts from muted-green (cheap) → yellow → orange → red (expensive)
    var activityColor: Color {
        switch costFraction {
        case 0..<0.05:  return .green
        case 0.05..<0.2: return .teal
        case 0.2..<0.5:  return .orange
        default:         return .red
        }
    }

    var body: some View {
        let duration = Int(session.lastTimestamp.timeIntervalSince(session.timestamp))
        // Background tint: more expensive = more visible
        let bgOpacity = 0.03 + costFraction * 0.09

        HStack(alignment: .top, spacing: 0) {
            // Left accent bar — width scales with costFraction
            RoundedRectangle(cornerRadius: 1.5)
                .fill(activityColor.opacity(0.5 + costFraction * 0.5))
                .frame(width: 3 + costFraction * 2)
                .padding(.trailing, 7)

            // Left: name / project+model / dates
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    // Status dot
                    Image(systemName: "circle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(session.hasError ? .red : activityColor)
                    Text(session.name)
                        .font(.caption)
                        .fontWeight(costFraction > 0.3 ? .semibold : .medium)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(session.project)
                    Text("·").foregroundStyle(.tertiary)
                    Text(session.primaryModel.isEmpty ? "unknown" : session.primaryModel)
                        .lineLimit(1).truncationMode(.middle)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                HStack(spacing: 4) {
                    Text(shortDateFmt.string(from: session.timestamp))
                    if duration > 5 {
                        Text("→").foregroundStyle(.tertiary)
                        Text(shortDateFmt.string(from: session.lastTimestamp))
                    }
                    // show "X ago" only if the session ended less than 24h ago
                    let secsAgo = Int(Date().timeIntervalSince(session.lastTimestamp))
                    if secsAgo < 86400 {
                        Text("(\(timeAgo(from: session.lastTimestamp)))").foregroundStyle(.tertiary)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                // 4th line: cache details, visible on hover
                if hovered {
                    let cacheCtx = session.rawInputTokens + session.cacheReadTokens + session.cacheWriteTokens
                    let hitPct   = cacheCtx > 0 ? Int(Double(session.cacheReadTokens) / Double(cacheCtx) * 100) : 0
                    let saved    = session.cacheReadCost * 9
                    HStack(spacing: 6) {
                        Text("↩")
                            .foregroundStyle(.tertiary)
                        Text("\(hitPct)% hit")
                        Text("·").foregroundStyle(.tertiary)
                        Text("\(fmtTokens(session.cacheReadTokens)) cached")
                        Text("·").foregroundStyle(.tertiary)
                        Text("~\(fmtCost(saved)) saved")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                // 5th line: delete button, visible on hover
                if hovered {
                    Divider().padding(.vertical, 2)
                    Button {
                        NSWorkspace.shared.recycle([session.filePath]) { _, _ in
                            DispatchQueue.main.async { onDelete() }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                            Text("Delete this session")
                        }
                        .font(.caption2)
                        .foregroundStyle(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            // Right: metric grid (numbers only, labels on hover)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(alignment: .bottom, spacing: 8) {
                    MetricCell(value: fmtCost(session.totalCost),     label: "cost",       showLabel: hovered, color: costFraction > 0.2 ? activityColor : .primary)
                    MetricCell(value: fmtTokens(session.totalTokens), label: "tokens",     showLabel: hovered)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    MetricCell(value: "\(session.userMessageCount)",  label: "user msgs",  showLabel: hovered)
                    MetricCell(value: "\(session.toolCallCount)",     label: "tool calls", showLabel: hovered)
                }
                MetricCell(value: duration > 0 ? fmtDuration(duration) : "—",
                           label: "duration", showLabel: hovered)
            }
        }
        .padding(.leading, 8)
        .padding([.trailing, .top, .bottom], 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(activityColor.opacity(bgOpacity))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(activityColor.opacity(costFraction * 0.25), lineWidth: 1)
        )
        .onHover { hovered = $0 }
    }
}
