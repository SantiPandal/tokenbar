import AppKit
import Combine
import Foundation
import SwiftUI

enum PeriodKind: String, CaseIterable, Identifiable {
    case day = "Day"
    case week = "Week"
    case month = "Month"

    var id: String { rawValue }
}

enum TokenSource: String, CaseIterable, Identifiable {
    case codex = "Codex"
    case claude = "Claude"

    var id: String { rawValue }
}

struct TokenTotals: Equatable {
    var consumed: Int64 = 0
    var produced: Int64 = 0
    var cached: Int64 = 0
    var reasoning: Int64 = 0
    var events: Int = 0

    var total: Int64 { consumed + produced }

    mutating func add(_ event: TokenEvent) {
        consumed += event.consumed
        produced += event.produced
        cached += event.cached
        reasoning += event.reasoning
        events += 1
    }

    mutating func add(_ other: TokenTotals) {
        consumed += other.consumed
        produced += other.produced
        cached += other.cached
        reasoning += other.reasoning
        events += other.events
    }
}

struct TokenEvent {
    let id: String
    let timestamp: Date
    let source: TokenSource
    let model: String
    let consumed: Int64
    let produced: Int64
    let cached: Int64
    let reasoning: Int64
}

struct SourceBreakdown: Identifiable {
    let source: TokenSource
    let totals: TokenTotals

    var id: String { source.rawValue }
}

struct ModelBreakdown: Identifiable {
    let name: String
    let source: TokenSource?
    let totals: TokenTotals

    var id: String { "\(source?.rawValue ?? "mixed"):\(name)" }
}

struct DayBucket: Identifiable {
    let date: Date
    let totals: TokenTotals

    var id: Date { date }
}

struct PeriodStats {
    let kind: PeriodKind
    let interval: DateInterval
    let totals: TokenTotals
    let sources: [SourceBreakdown]
    let models: [ModelBreakdown]
    let days: [DayBucket]
}

struct TokenSnapshot {
    var periods: [PeriodKind: PeriodStats] = [:]
    var indexedFiles: Int = 0
    var indexedEvents: Int = 0
    var indexedBytes: Int64 = 0
    var lastUpdated: Date = .distantPast
    var isIndexing: Bool = true
    var warning: String?

    static let empty = TokenSnapshot()
}

final class TokenMonitor: ObservableObject, @unchecked Sendable {
    @Published private(set) var snapshot: TokenSnapshot = .empty

    private let queue = DispatchQueue(label: "tokenbar.indexer", qos: .utility)
    private let indexer = LogIndexer()
    private var timer: Timer?
    private var isRefreshRunning = false

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        timer?.invalidate()
    }

    func refresh() {
        queue.async { [weak self] in
            guard let self, !self.isRefreshRunning else { return }
            self.isRefreshRunning = true
            var nextSnapshot = self.indexer.scan()
            self.isRefreshRunning = false

            DispatchQueue.main.async {
                nextSnapshot.isIndexing = false
                self.snapshot = nextSnapshot
            }
        }
    }
}

final class PopoverVisibility: ObservableObject {
    @Published var isVisible = false
}

final class LogIndexer: @unchecked Sendable {
    private let fileManager = FileManager.default
    private let home: URL
    private var candidateFiles: Set<URL> = []
    private var hotFiles: Set<URL> = []
    private var offsets: [URL: UInt64] = [:]
    private var partialLines: [URL: String] = [:]
    private var events: [String: TokenEvent] = [:]
    private var codexModelsByFile: [URL: String] = [:]
    private var lastDiscovery: Date?
    private var indexedBytes: Int64 = 0
    private var warning: String?

    private let isoWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let isoWithoutFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    func scan() -> TokenSnapshot {
        let now = Date()
        let shouldDiscover = lastDiscovery == nil || now.timeIntervalSince(lastDiscovery ?? .distantPast) > 30
        let filesToScan: Set<URL>

        if shouldDiscover {
            candidateFiles = discoverCandidateFiles(now: now)
            hotFiles = Set(candidateFiles.filter { modified($0, since: now.addingTimeInterval(-15 * 60)) })
            lastDiscovery = now
            filesToScan = candidateFiles
        } else {
            filesToScan = hotFiles
        }

        for file in filesToScan {
            scanFile(file)
        }

        pruneOldEvents(now: now)
        return buildSnapshot(now: now)
    }

    private func discoverCandidateFiles(now: Date) -> Set<URL> {
        var files = Set<URL>()
        let calendar = Self.productivityCalendar
        let monthInterval = calendar.dateInterval(of: .month, for: now)
        let monthStart = monthInterval?.start ?? calendar.startOfDay(for: now)
        let components = calendar.dateComponents([.year, .month], from: now)

        if let year = components.year, let month = components.month {
            let codexMonth = home
                .appendingPathComponent(".codex/sessions")
                .appendingPathComponent(String(format: "%04d", year))
                .appendingPathComponent(String(format: "%02d", month))
            files.formUnion(jsonlFiles(under: codexMonth, modifiedSince: nil))

            let archivePrefix = String(format: "rollout-%04d-%02d", year, month)
            let archiveRoot = home.appendingPathComponent(".codex/archived_sessions")
            for file in jsonlFiles(under: archiveRoot, modifiedSince: monthStart) {
                if file.lastPathComponent.hasPrefix(archivePrefix) || modified(file, since: monthStart) {
                    files.insert(file)
                }
            }
        }

        let claudeRoot = home.appendingPathComponent(".claude/projects")
        files.formUnion(jsonlFiles(under: claudeRoot, modifiedSince: monthStart))

        return files
    }

    private func jsonlFiles(under root: URL, modifiedSince start: Date?) -> Set<URL> {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        var files = Set<URL>()
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        for case let file as URL in enumerator {
            guard file.pathExtension == "jsonl" else { continue }
            if let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
               values.isRegularFile != true {
                continue
            }
            if let start, !modified(file, since: start) {
                continue
            }
            files.insert(file)
        }
        return files
    }

    private func modified(_ file: URL, since start: Date) -> Bool {
        guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
              let modifiedAt = values.contentModificationDate else {
            return true
        }
        return modifiedAt >= start
    }

    private func scanFile(_ file: URL) {
        guard let attrs = try? fileManager.attributesOfItem(atPath: file.path),
              let sizeNumber = attrs[.size] as? NSNumber else {
            return
        }

        let size = sizeNumber.uint64Value
        let previousOffset = offsets[file] ?? 0

        if size < previousOffset {
            offsets[file] = 0
            partialLines[file] = nil
            codexModelsByFile[file] = nil
        }

        let offset = offsets[file] ?? 0
        guard size > offset else { return }

        do {
            let handle = try FileHandle(forReadingFrom: file)
            try handle.seek(toOffset: offset)

            var pending = partialLines[file] ?? ""
            let chunkSize = 1024 * 1024

            while let data = try handle.read(upToCount: chunkSize), !data.isEmpty {
                indexedBytes += Int64(data.count)
                autoreleasepool {
                    let chunk = String(data: data, encoding: .utf8) ?? ""
                    let text = pending + chunk
                    let hasCompleteFinalLine = text.hasSuffix("\n")
                    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

                    if !hasCompleteFinalLine, let last = lines.popLast() {
                        pending = last
                    } else {
                        pending = ""
                    }

                    for line in lines where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        parseLine(line, from: file)
                    }
                }
            }

            offsets[file] = try handle.offset()
            partialLines[file] = pending.isEmpty ? nil : pending
            try handle.close()
        } catch {
            warning = "Could not read \(file.lastPathComponent)"
        }
    }

    private func parseLine(_ line: String, from file: URL) {
        guard let data = line.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let object = raw as? [String: Any] else {
            return
        }

        if file.path.contains("/.codex/") {
            parseCodex(object, from: file)
        } else if file.path.contains("/.claude/") {
            parseClaude(object)
        }
    }

    private func parseCodex(_ object: [String: Any], from file: URL) {
        if object["type"] as? String == "turn_context",
           let payload = object["payload"] as? [String: Any] {
            let collaboration = payload["collaboration_mode"] as? [String: Any]
            let settings = collaboration?["settings"] as? [String: Any]
            let rawModel = nonEmptyString(payload["model"]) ?? nonEmptyString(settings?["model"])
            if let rawModel {
                codexModelsByFile[file] = modelLabel(rawModel, fallback: "Codex")
            }
            return
        }

        guard let timestampText = object["timestamp"] as? String,
              let timestamp = parseDate(timestampText),
              let type = object["type"] as? String,
              type == "event_msg",
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let usage = info["last_token_usage"] as? [String: Any] else {
            return
        }

        let consumed = int64(usage["input_tokens"])
        let cached = int64(usage["cached_input_tokens"])
        let produced = int64(usage["output_tokens"])
        let reasoning = int64(usage["reasoning_output_tokens"])
        let total = int64(usage["total_tokens"])
        guard consumed > 0 || produced > 0 else { return }

        let model = codexModelsByFile[file] ?? modelLabel(nonEmptyString(info["model"]), fallback: "Codex")
        let id = "codex:\(model):\(timestampText):\(consumed):\(cached):\(produced):\(reasoning):\(total)"
        events[id] = TokenEvent(
            id: id,
            timestamp: timestamp,
            source: .codex,
            model: model,
            consumed: consumed,
            produced: produced,
            cached: cached,
            reasoning: reasoning
        )
    }

    private func parseClaude(_ object: [String: Any]) {
        guard let timestampText = object["timestamp"] as? String,
              let timestamp = parseDate(timestampText),
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else {
            return
        }

        let requestID = object["requestId"] as? String
            ?? message["id"] as? String
            ?? object["uuid"] as? String
            ?? "\(timestampText):\(int64(usage["input_tokens"])):\(int64(usage["output_tokens"]))"

        let freshInput = int64(usage["input_tokens"])
        let cacheRead = int64(usage["cache_read_input_tokens"])
        let cacheCreation = int64(usage["cache_creation_input_tokens"])
        let produced = int64(usage["output_tokens"])
        let consumed = freshInput + cacheRead + cacheCreation
        guard consumed > 0 || produced > 0 else { return }

        let model = modelLabel(nonEmptyString(message["model"]) ?? nonEmptyString(object["model"]), fallback: "Claude")
        let id = "claude:\(requestID)"
        events[id] = TokenEvent(
            id: id,
            timestamp: timestamp,
            source: .claude,
            model: model,
            consumed: consumed,
            produced: produced,
            cached: cacheRead + cacheCreation,
            reasoning: 0
        )
    }

    private func pruneOldEvents(now: Date) {
        guard let monthStart = Self.productivityCalendar.dateInterval(of: .month, for: now)?.start else {
            return
        }
        events = events.filter { _, event in
            event.timestamp >= monthStart
        }
    }

    private func buildSnapshot(now: Date) -> TokenSnapshot {
        let calendar = Self.productivityCalendar
        let periods: [PeriodKind: DateInterval] = [
            .day: DateInterval(start: calendar.startOfDay(for: now), end: now.addingTimeInterval(1)),
            .week: calendar.dateInterval(of: .weekOfYear, for: now) ?? DateInterval(start: now.addingTimeInterval(-7 * 24 * 60 * 60), end: now),
            .month: calendar.dateInterval(of: .month, for: now) ?? DateInterval(start: now.addingTimeInterval(-30 * 24 * 60 * 60), end: now)
        ]

        var stats: [PeriodKind: PeriodStats] = [:]
        for kind in PeriodKind.allCases {
            guard let interval = periods[kind] else { continue }
            var totals = TokenTotals()
            var sourceTotals: [TokenSource: TokenTotals] = [:]
            var modelTotals: [String: TokenTotals] = [:]
            var modelNames: [String: String] = [:]
            var modelSources: [String: TokenSource] = [:]
            var dayTotals: [Date: TokenTotals] = [:]

            for event in events.values where interval.contains(event.timestamp) {
                totals.add(event)
                sourceTotals[event.source, default: TokenTotals()].add(event)
                let modelKey = "\(event.source.rawValue)|\(event.model)"
                modelTotals[modelKey, default: TokenTotals()].add(event)
                modelNames[modelKey] = event.model
                modelSources[modelKey] = event.source
                let bucket = bucketStart(for: event.timestamp, kind: kind, calendar: calendar)
                dayTotals[bucket, default: TokenTotals()].add(event)
            }

            let sources = TokenSource.allCases.map { source in
                SourceBreakdown(source: source, totals: sourceTotals[source] ?? TokenTotals())
            }
            let models = modelTotals.map { key, totals in
                ModelBreakdown(
                    name: modelNames[key] ?? key,
                    source: modelSources[key],
                    totals: totals
                )
            }
            .sorted {
                if $0.totals.total == $1.totals.total {
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                return $0.totals.total > $1.totals.total
            }
            let days = buckets(for: kind, interval: interval, now: now, calendar: calendar)
                .map { DayBucket(date: $0, totals: dayTotals[$0] ?? TokenTotals()) }

            stats[kind] = PeriodStats(
                kind: kind,
                interval: interval,
                totals: totals,
                sources: sources,
                models: models,
                days: days
            )
        }

        return TokenSnapshot(
            periods: stats,
            indexedFiles: candidateFiles.count,
            indexedEvents: events.count,
            indexedBytes: indexedBytes,
            lastUpdated: now,
            isIndexing: false,
            warning: warning
        )
    }

    private func parseDate(_ value: String) -> Date? {
        isoWithFractional.date(from: value) ?? isoWithoutFractional.date(from: value)
    }

    private func bucketStart(for date: Date, kind: PeriodKind, calendar: Calendar) -> Date {
        if kind == .day {
            return calendar.dateInterval(of: .hour, for: date)?.start ?? date
        }
        return calendar.startOfDay(for: date)
    }

    private func buckets(for kind: PeriodKind, interval: DateInterval, now: Date, calendar: Calendar) -> [Date] {
        let component: Calendar.Component = kind == .day ? .hour : .day
        let start = bucketStart(for: interval.start, kind: kind, calendar: calendar)
        let end = bucketStart(for: min(now, interval.end), kind: kind, calendar: calendar)
        var buckets: [Date] = []
        var cursor = start

        while cursor <= end {
            buckets.append(cursor)
            guard let next = calendar.date(byAdding: component, value: 1, to: cursor) else { break }
            cursor = next
        }

        return buckets
    }

    private func int64(_ value: Any?) -> Int64 {
        if let int = value as? Int { return Int64(int) }
        if let int64 = value as? Int64 { return int64 }
        if let double = value as? Double { return Int64(double) }
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) ?? 0 }
        return 0
    }

    private func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func modelLabel(_ value: String?, fallback: String) -> String {
        guard let value = nonEmptyString(value) else { return fallback }
        let lowercased = value.lowercased()

        if lowercased.hasPrefix("gpt-") {
            let parts = value.split(separator: "-").map(String.init)
            guard parts.count >= 2 else { return value }
            let suffix = parts.dropFirst(2).map { $0.capitalized }.joined(separator: " ")
            return suffix.isEmpty ? "GPT-\(parts[1])" : "GPT-\(parts[1]) \(suffix)"
        }

        if lowercased.hasPrefix("claude-") {
            var parts = value.split(separator: "-").map(String.init)
            parts.removeFirst()
            if let last = parts.last, isNumeric(last), last.count >= 6 {
                parts.removeLast()
            }

            guard let family = parts.first else { return "Claude" }
            let rest = Array(parts.dropFirst())
            if rest.count >= 2, isNumeric(rest[0]), isNumeric(rest[1]) {
                return "Claude \(family.capitalized) \(rest[0]).\(rest[1])"
            }
            return "Claude " + parts.map { $0.capitalized }.joined(separator: " ")
        }

        return value
    }

    private func isNumeric(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
    }

    private static let productivityCalendar: Calendar = {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        return calendar
    }()
}

@main
struct TokenBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let monitor = TokenMonitor()
    private let visibility = PopoverVisibility()
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--print-snapshot") {
            let snapshot = LogIndexer().scan()
            for period in PeriodKind.allCases {
                guard let stats = snapshot.periods[period] else { continue }
                print("\(period.rawValue.lowercased()) total=\(stats.totals.total) consumed=\(stats.totals.consumed) produced=\(stats.totals.produced) cached=\(stats.totals.cached) events=\(stats.totals.events)")
                for model in stats.models.prefix(6) {
                    print("  model=\(model.name) total=\(model.totals.total) consumed=\(model.totals.consumed) produced=\(model.totals.produced)")
                }
            }
            print("files=\(snapshot.indexedFiles) events=\(snapshot.indexedEvents) bytes=\(snapshot.indexedBytes)")
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "Tokens")
            button.image?.isTemplate = true
            button.title = "Indexing"
            button.action = #selector(togglePopover)
            button.target = self
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 380, height: 590)
        popover.contentViewController = NSHostingController(rootView: TokenPopoverView(monitor: monitor, visibility: visibility))
        self.popover = popover

        monitor.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.updateStatusTitle(snapshot)
            }
            .store(in: &cancellables)
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }

        if popover.isShown {
            visibility.isVisible = false
            popover.performClose(nil)
        } else {
            visibility.isVisible = true
            monitor.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        visibility.isVisible = false
    }

    private func updateStatusTitle(_ snapshot: TokenSnapshot) {
        let todayTotal = snapshot.periods[.day]?.totals.total ?? 0
        let title = snapshot.isIndexing ? "Indexing" : ShortFormat.tokens(todayTotal)
        statusItem?.button?.title = " \(title)"
    }
}

struct TokenPopoverView: View {
    @ObservedObject var monitor: TokenMonitor
    @ObservedObject var visibility: PopoverVisibility
    @State private var period: PeriodKind = .day

    var body: some View {
        let snapshot = monitor.snapshot
        let stats = snapshot.periods[period]

        VStack(alignment: .leading, spacing: 16) {
            header(snapshot: snapshot, stats: stats)

            Picker("", selection: $period) {
                ForEach(PeriodKind.allCases) { period in
                    Text(period.rawValue).tag(period)
                }
            }
            .pickerStyle(.segmented)

            if let stats {
                metrics(totals: stats.totals)
                modelList(stats.models)
                miniChart(stats.days)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 180)
            }

            Spacer(minLength: 0)
            footer(snapshot: snapshot)
        }
        .padding(.top, 12)
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .frame(width: 380, height: 590)
        .background(.regularMaterial)
    }

    private func header(snapshot: TokenSnapshot, stats: PeriodStats?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Tokens")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                LivePill(isIndexing: snapshot.isIndexing, isActive: visibility.isVisible)
            }

            Text(ShortFormat.full(stats?.totals.total ?? 0))
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.78)

            Text(periodLabel(stats?.interval))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func metrics(totals: TokenTotals) -> some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                MetricTile(title: "Consumed", value: totals.consumed, tint: .blue)
                MetricTile(title: "Produced", value: totals.produced, tint: .green)
            }
            GridRow {
                MetricTile(title: "Cached", value: totals.cached, tint: .purple)
                MetricTile(title: "Reasoning", value: totals.reasoning, tint: .orange)
            }
        }
    }

    private func sourceList(_ sources: [SourceBreakdown]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sources")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            ForEach(sources) { source in
                HStack(spacing: 10) {
                    Image(systemName: source.source == .codex ? "terminal" : "sparkles")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 20)
                        .foregroundStyle(source.source == .codex ? .blue : .purple)
                    Text(source.source.rawValue)
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text(ShortFormat.tokens(source.totals.total))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func modelList(_ models: [ModelBreakdown]) -> some View {
        let rows = compactedModels(models)

        return VStack(alignment: .leading, spacing: 7) {
            Text(modelSectionTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            if rows.isEmpty {
                Text("No model data yet")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                ForEach(rows) { model in
                    HStack(spacing: 10) {
                        Image(systemName: modelIcon(model.source))
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 20)
                            .foregroundStyle(modelTint(model.source))
                        Text(model.name)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(ShortFormat.tokens(model.totals.total))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .help("\(model.name): \(ShortFormat.full(model.totals.total)) total, \(ShortFormat.full(model.totals.consumed)) consumed, \(ShortFormat.full(model.totals.produced)) produced")
                }
            }
        }
    }

    private func compactedModels(_ models: [ModelBreakdown]) -> [ModelBreakdown] {
        let visibleLimit = 3
        guard models.count > visibleLimit + 1 else { return models }

        var otherTotals = TokenTotals()
        for model in models.dropFirst(visibleLimit) {
            otherTotals.add(model.totals)
        }

        return Array(models.prefix(visibleLimit)) + [
            ModelBreakdown(name: "Other models", source: nil, totals: otherTotals)
        ]
    }

    private func modelIcon(_ source: TokenSource?) -> String {
        switch source {
        case .codex:
            return "terminal"
        case .claude:
            return "sparkles"
        case nil:
            return "ellipsis.circle"
        }
    }

    private func modelTint(_ source: TokenSource?) -> Color {
        switch source {
        case .codex:
            return .blue
        case .claude:
            return .purple
        case nil:
            return .secondary
        }
    }

    private func miniChart(_ days: [DayBucket]) -> some View {
        let maxValue = max(days.map { $0.totals.total }.max() ?? 1, 1)
        let barWidth: CGFloat = days.count > 24 ? 7 : (days.count > 14 ? 9 : 14)
        let spacing: CGFloat = days.count > 24 ? 3 : 5

        return VStack(alignment: .leading, spacing: 8) {
            Text(chartTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            HStack(alignment: .bottom, spacing: spacing) {
                if days.isEmpty {
                    Text("No tokens yet")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 58)
                } else {
                    ForEach(days) { day in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(day.totals.total == 0 ? Color.secondary.opacity(0.18) : Color.blue)
                            .frame(width: barWidth, height: max(5, CGFloat(day.totals.total) / CGFloat(maxValue) * 58))
                            .help("\(bucketLabel(day.date)): \(ShortFormat.full(day.totals.total))")
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 64)

            if let first = days.first?.date, let last = days.last?.date {
                HStack {
                    Text(axisLabel(first, isStart: true))
                    Spacer()
                    Text(axisLabel(last, isStart: false))
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            }
        }
    }

    private func footer(snapshot: TokenSnapshot) -> some View {
        HStack {
            Text("\(snapshot.indexedEvents) events")
            Text("·")
            Text("\(snapshot.indexedFiles) files")
            Spacer()
            Text(snapshot.lastUpdated == .distantPast ? "Starting" : timeLabel(snapshot.lastUpdated))
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
    }

    private func periodLabel(_ interval: DateInterval?) -> String {
        guard let interval else { return "Indexing local logs" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        if period == .day {
            return formatter.string(from: interval.start)
        }
        let end = interval.end.addingTimeInterval(-1)
        return "\(formatter.string(from: interval.start)) - \(formatter.string(from: end))"
    }

    private func bucketLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = period == .day ? "HH:00" : "MMM d"
        return formatter.string(from: date)
    }

    private func axisLabel(_ date: Date, isStart: Bool) -> String {
        if period == .day {
            return isStart ? "12 AM" : "Now"
        }

        let formatter = DateFormatter()
        formatter.dateFormat = period == .week ? "EEE" : "MMM d"
        return isStart ? formatter.string(from: date) : "Today"
    }

    private var chartTitle: String {
        switch period {
        case .day:
            return "Hourly tokens today"
        case .week:
            return "Daily tokens this week"
        case .month:
            return "Daily tokens this month"
        }
    }

    private var modelSectionTitle: String {
        switch period {
        case .day:
            return "Models today"
        case .week:
            return "Models this week"
        case .month:
            return "Models this month"
        }
    }

    private func timeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}

struct MetricTile: View {
    let title: String
    let value: Int64
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(ShortFormat.tokens(value))
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct LivePill: View {
    let isIndexing: Bool
    let isActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            indicator
            Text(isIndexing ? "Indexing" : "Live")
                .font(.system(size: 12, weight: .semibold))
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 9)
        .background(.quaternary.opacity(0.75), in: Capsule())
    }

    @ViewBuilder
    private var indicator: some View {
        if !isIndexing && isActive {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let phase = (sin(timeline.date.timeIntervalSinceReferenceDate * Double.pi * 2 / 1.35) + 1) / 2
                let haloScale = 0.58 + (0.42 * phase)
                let haloOpacity = 0.28 - (0.2 * phase)
                let dotOpacity = 0.72 + (0.28 * phase)

                liveDot(haloScale: haloScale, haloOpacity: haloOpacity, dotOpacity: dotOpacity)
            }
            .frame(width: 15, height: 15)
        } else {
            liveDot(haloScale: 0.58, haloOpacity: 0, dotOpacity: 1)
        }
    }

    private func liveDot(haloScale: Double, haloOpacity: Double, dotOpacity: Double) -> some View {
        ZStack {
            Circle()
                .fill(isIndexing ? Color.orange.opacity(0.18) : Color.green.opacity(0.18))
                .frame(width: 15, height: 15)
                .scaleEffect(CGFloat(haloScale))
                .opacity(haloOpacity)
            Circle()
                .fill(isIndexing ? .orange : .green)
                .frame(width: 7, height: 7)
                .opacity(dotOpacity)
        }
        .frame(width: 15, height: 15)
    }
}

enum ShortFormat {
    static func tokens(_ value: Int64) -> String {
        let absolute = Double(abs(value))
        let sign = value < 0 ? "-" : ""

        switch absolute {
        case 1_000_000_000...:
            return "\(sign)\(decimal(absolute / 1_000_000_000))B"
        case 1_000_000...:
            return "\(sign)\(decimal(absolute / 1_000_000))M"
        case 1_000...:
            return "\(sign)\(decimal(absolute / 1_000))K"
        default:
            return "\(value)"
        }
    }

    static func full(_ value: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static func decimal(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = value < 10 ? 1 : 0
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
    }
}
