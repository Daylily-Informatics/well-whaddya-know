// SPDX-License-Identifier: MIT
// ViewerWindow.swift - Viewer/Editor window per SPEC.md Section 9.2

import SwiftUI
import Charts
import CoreModel
import Timeline
import Reporting
import XPCProtocol
import UniformTypeIdentifiers

/// Viewer/Editor window with Timeline, Tags, and Exports tabs
struct ViewerWindow: View {
    @StateObject private var viewModel = ViewerViewModel()
    @State private var selectedTab: ViewerTab = .timeline

    var body: some View {
        NavigationSplitView {
            List(ViewerTab.allCases, selection: $selectedTab) { tab in
                Label(tab.title, systemImage: tab.icon)
                    .tag(tab)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 180, max: 220)
        } detail: {
            Group {
                switch selectedTab {
                case .timeline:
                    TimelineTabView(viewModel: viewModel)
                case .reports:
                    ReportsTabView(viewModel: viewModel)
                case .tags:
                    TagsTabView(viewModel: viewModel)
                case .exports:
                    ExportsTabView(viewModel: viewModel)
                }
            }
            .navigationTitle(selectedTab.title)
        }
        .frame(minWidth: 800, minHeight: 500)
    }
}

/// Tab options for the viewer window
enum ViewerTab: String, CaseIterable, Identifiable {
    case timeline
    case reports
    case tags
    case exports

    var id: String { rawValue }

    var title: String {
        switch self {
        case .timeline: return "Timeline"
        case .reports: return "Reports"
        case .tags: return "Tags"
        case .exports: return "Exports"
        }
    }

    var icon: String {
        switch self {
        case .timeline: return "clock"
        case .reports: return "chart.bar"
        case .tags: return "tag"
        case .exports: return "square.and.arrow.up"
        }
    }
}

/// Date range presets for Timeline and Exports views
enum DateRangePreset: String, CaseIterable, Identifiable {
    case today
    case yesterday
    case thisWeek
    case last7Days
    case thisMonth
    case last30Days
    case last12Months
    case yearToDate
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .thisWeek: return "This Week"
        case .last7Days: return "Last 7 Days"
        case .thisMonth: return "This Month"
        case .last30Days: return "Last 30 Days"
        case .last12Months: return "Last 12 Months"
        case .yearToDate: return "YTD"
        case .custom: return "Custom"
        }
    }

    /// Compute (start, end) for this preset relative to now,
    /// using the user's preferred display timezone.
    /// For ranges that include the current day, end is capped at `now`
    /// (not end-of-day) so durations reflect elapsed time, not future time.
    func dateRange() -> (start: Date, end: Date)? {
        let calendar = DisplayTimezoneHelper.calendar
        let now = Date()

        switch self {
        case .today:
            return (calendar.startOfDay(for: now), now)
        case .yesterday:
            let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
            return (calendar.startOfDay(for: yesterday), Self.endOfDay(yesterday, calendar: calendar))
        case .thisWeek:
            let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
            return (weekStart, now)
        case .last7Days:
            let start = calendar.date(byAdding: .day, value: -6, to: now)!
            return (calendar.startOfDay(for: start), now)
        case .thisMonth:
            let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? now
            return (monthStart, now)
        case .last30Days:
            let start = calendar.date(byAdding: .day, value: -29, to: now)!
            return (calendar.startOfDay(for: start), now)
        case .last12Months:
            let start = calendar.date(byAdding: .month, value: -12, to: now)!
            return (calendar.startOfDay(for: start), now)
        case .yearToDate:
            var comps = calendar.dateComponents([.year], from: now)
            comps.month = 1; comps.day = 1
            let yearStart = calendar.date(from: comps) ?? now
            return (yearStart, now)
        case .custom:
            return nil
        }
    }

    private static func endOfDay(_ date: Date, calendar: Calendar) -> Date {
        var comps = calendar.dateComponents([.year, .month, .day], from: date)
        comps.hour = 23; comps.minute = 59; comps.second = 59
        return calendar.date(from: comps) ?? date
    }
}

/// View model for the viewer window
@MainActor
final class ViewerViewModel: ObservableObject {
    @Published var selectedDate: Date = Date()
    @Published var startTime: Date = DisplayTimezoneHelper.calendar.startOfDay(for: Date())
    @Published var endTime: Date = Date()
    @Published var selectedPreset: DateRangePreset = .today
    @Published var segments: [TimelineSegment] = []
    @Published var tags: [TagItem] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    // Reports tab state
    @Published var reportPreset: DateRangePreset = .today
    @Published var reportStartTime: Date = DisplayTimezoneHelper.calendar.startOfDay(for: Date())
    @Published var reportEndTime: Date = Date()
    @Published var reportByApp: [ReportRow] = []
    @Published var reportByAppWindow: [ReportRow] = []
    @Published var reportByTag: [ReportRow] = []
    @Published var reportSegments: [EffectiveSegment] = []
    @Published var isLoadingReports: Bool = false
    @Published var reportAppFilter: String? = nil

    /// All loaded segments before filter — kept so filter toggle doesn't re-query DB
    private var allReportSegments: [EffectiveSegment] = []

    private let xpcClient = XPCClient()

    /// Reset time pickers to full-day range for the given date
    func resetTimeRange(for date: Date) {
        let calendar = DisplayTimezoneHelper.calendar
        startTime = calendar.startOfDay(for: date)
        var comps = calendar.dateComponents([.year, .month, .day], from: date)
        comps.hour = 23; comps.minute = 59; comps.second = 59
        endTime = calendar.date(from: comps) ?? date
    }

    /// Apply a date range preset
    func applyPreset(_ preset: DateRangePreset) async {
        selectedPreset = preset
        guard let range = preset.dateRange() else { return } // .custom — don't change
        startTime = range.start
        endTime = range.end
        selectedDate = range.start
        await loadTimelineForRange()
    }

    /// Load timeline for the selected date (full day) — used by date nav buttons
    func loadTimeline(for date: Date) async {
        selectedPreset = .custom
        resetTimeRange(for: date)
        await loadTimelineForRange()
    }

    /// Load timeline using current startTime/endTime — used by Apply button
    func loadTimelineForRange() async {
        isLoading = true
        defer { isLoading = false }

        let startTsUs = Int64(startTime.timeIntervalSince1970 * 1_000_000)
        let endTsUs = Int64(endTime.timeIntervalSince1970 * 1_000_000)

        print("[ViewerVM] loadTimelineForRange: startTsUs=\(startTsUs) endTsUs=\(endTsUs)")
        print("[ViewerVM] startTime=\(startTime) endTime=\(endTime)")

        guard startTsUs < endTsUs else {
            errorMessage = "Start time must be before end time"
            segments = []
            return
        }
        errorMessage = nil

        // Read timeline from database
        let effectiveSegments = await ViewerDatabaseReader.loadTimeline(
            startTsUs: startTsUs,
            endTsUs: endTsUs
        )

        print("[ViewerVM] effectiveSegments count: \(effectiveSegments.count)")

        // Convert to display segments
        let rawSegments = effectiveSegments.map { seg in
            TimelineSegment(
                startTime: Date(timeIntervalSince1970: Double(seg.startTsUs) / 1_000_000),
                endTime: Date(timeIntervalSince1970: Double(seg.endTsUs) / 1_000_000),
                appName: seg.appName,
                bundleId: seg.appBundleId,
                windowTitle: seg.windowTitle,
                tags: seg.tags,
                isGap: seg.coverage == .unobservedGap
            )
        }

        // Merge contiguous segments with same app + window title + tags + gap status.
        // Display-time only — underlying events remain immutable.
        segments = Self.mergeContiguousSegments(rawSegments)
        print("[ViewerVM] display segments count: \(segments.count) (from \(rawSegments.count) raw)")
    }

    // MARK: - Segment Merging

    /// Merge consecutive display segments that share the same app, window title, tags, and gap status.
    /// Tolerance: segments whose gap is ≤ 1 second are considered contiguous.
    static func mergeContiguousSegments(_ segments: [TimelineSegment]) -> [TimelineSegment] {
        guard var current = segments.first else { return [] }
        var merged: [TimelineSegment] = []

        for next in segments.dropFirst() {
            let gap = next.startTime.timeIntervalSince(current.endTime)
            let sameContent = current.appName == next.appName
                && current.bundleId == next.bundleId
                && current.windowTitle == next.windowTitle
                && current.tags == next.tags
                && current.isGap == next.isGap
            if sameContent && gap >= 0 && gap <= 1.0 {
                // Extend current segment to cover next
                current = TimelineSegment(
                    startTime: current.startTime,
                    endTime: next.endTime,
                    appName: current.appName,
                    bundleId: current.bundleId,
                    windowTitle: current.windowTitle,
                    tags: current.tags,
                    isGap: current.isGap
                )
            } else {
                merged.append(current)
                current = next
            }
        }
        merged.append(current)
        return merged
    }

    func loadTags() async {
        // Load tags from database
        tags = await ViewerDatabaseReader.loadTags().map { dbTag in
            TagItem(
                id: dbTag.tagId,
                name: dbTag.name,
                createdDate: Date(timeIntervalSince1970: Double(dbTag.createdTsUs) / 1_000_000),
                isRetired: dbTag.isRetired
            )
        }
    }

    // MARK: - Edit Operations

    func deleteRange(startTime: Date, endTime: Date, note: String? = nil) async {
        let startTsUs = Int64(startTime.timeIntervalSince1970 * 1_000_000)
        let endTsUs = Int64(endTime.timeIntervalSince1970 * 1_000_000)

        let request = DeleteRangeRequest(
            startTsUs: startTsUs,
            endTsUs: endTsUs,
            note: note
        )

        do {
            let _ = try await xpcClient.deleteRange(request)
            // Reload timeline after edit
            await loadTimeline(for: selectedDate)
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
        }
    }

    func applyTag(startTime: Date, endTime: Date, tagName: String) async {
        let startTsUs = Int64(startTime.timeIntervalSince1970 * 1_000_000)
        let endTsUs = Int64(endTime.timeIntervalSince1970 * 1_000_000)

        let request = TagRangeRequest(
            startTsUs: startTsUs,
            endTsUs: endTsUs,
            tagName: tagName
        )

        do {
            let _ = try await xpcClient.applyTag(request)
            // Reload timeline after edit
            await loadTimeline(for: selectedDate)
        } catch {
            errorMessage = "Apply tag failed: \(error.localizedDescription)"
        }
    }

    func removeTag(startTime: Date, endTime: Date, tagName: String) async {
        let startTsUs = Int64(startTime.timeIntervalSince1970 * 1_000_000)
        let endTsUs = Int64(endTime.timeIntervalSince1970 * 1_000_000)

        let request = TagRangeRequest(
            startTsUs: startTsUs,
            endTsUs: endTsUs,
            tagName: tagName
        )

        do {
            let _ = try await xpcClient.removeTag(request)
            // Reload timeline after edit
            await loadTimeline(for: selectedDate)
        } catch {
            errorMessage = "Remove tag failed: \(error.localizedDescription)"
        }
    }

    func createTag(name: String) async {
        do {
            let _ = try await xpcClient.createTag(name: name)
            await loadTags()
        } catch {
            errorMessage = "Create tag failed: \(error.localizedDescription)"
        }
    }

    func retireTag(name: String) async {
        do {
            try await xpcClient.retireTag(name: name)
            await loadTags()
        } catch {
            errorMessage = "Retire tag failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Reports

    /// Apply a report preset
    func applyReportPreset(_ preset: DateRangePreset) async {
        reportPreset = preset
        guard let range = preset.dateRange() else { return }
        reportStartTime = range.start
        reportEndTime = range.end
        await loadReports()
    }

    /// Load report aggregations for current report time range
    func loadReports() async {
        isLoadingReports = true
        defer { isLoadingReports = false }

        let startTsUs = Int64(reportStartTime.timeIntervalSince1970 * 1_000_000)
        let endTsUs = Int64(reportEndTime.timeIntervalSince1970 * 1_000_000)
        guard startTsUs < endTsUs else {
            reportByApp = []
            reportByAppWindow = []
            reportByTag = []
            reportSegments = []
            allReportSegments = []
            return
        }

        let segments = await ViewerDatabaseReader.loadTimeline(
            startTsUs: startTsUs,
            endTsUs: endTsUs
        )

        allReportSegments = segments
        recomputeReportAggregations()
    }

    /// Set or clear the app-name filter and recompute aggregations in-memory
    func setReportFilter(_ appName: String?) {
        reportAppFilter = appName
        recomputeReportAggregations()
    }

    /// Recompute report aggregations from stored segments, respecting filter
    private func recomputeReportAggregations() {
        let segments: [EffectiveSegment]
        if let filter = reportAppFilter {
            segments = allReportSegments.filter {
                $0.coverage == .observed && $0.appName == filter
            }
        } else {
            segments = allReportSegments
        }
        reportSegments = segments

        // By app (with inactive time)
        let byApp = Aggregations.totalsByAppName(segments: segments)
        let totalActiveSeconds = byApp.values.reduce(0.0, +)
        let effectiveEnd = min(reportEndTime, Date())
        let rangeDurationSeconds = max(0, effectiveEnd.timeIntervalSince(reportStartTime))
        let inactiveSeconds = max(0, rangeDurationSeconds - totalActiveSeconds)

        var appRows = byApp
            .map { ReportRow(appName: $0.key, windowTitle: nil, tagName: nil,
                             totalSeconds: $0.value,
                             percentage: rangeDurationSeconds > 0 ? $0.value / rangeDurationSeconds * 100 : 0) }
            .sorted { $0.totalSeconds > $1.totalSeconds }

        if inactiveSeconds > 0 {
            appRows.append(ReportRow(
                appName: "Inactive",
                windowTitle: nil,
                tagName: nil,
                totalSeconds: inactiveSeconds,
                percentage: rangeDurationSeconds > 0 ? inactiveSeconds / rangeDurationSeconds * 100 : 0
            ))
        }
        reportByApp = appRows

        // By app + window
        let byAppWin = Aggregations.totalsByAppNameAndWindow(segments: segments)
        let totalAW = byAppWin.reduce(0.0) { $0 + $1.seconds }
        reportByAppWindow = byAppWin
            .map { ReportRow(appName: $0.appName, windowTitle: $0.windowTitle, tagName: nil,
                             totalSeconds: $0.seconds,
                             percentage: totalAW > 0 ? $0.seconds / totalAW * 100 : 0) }

        // By tag
        let byTag = Aggregations.totalsByTag(segments: segments)
        let totalTag = byTag.values.reduce(0.0, +)
        reportByTag = byTag
            .map { ReportRow(appName: "", windowTitle: nil, tagName: $0.key,
                             totalSeconds: $0.value,
                             percentage: totalTag > 0 ? $0.value / totalTag * 100 : 0) }
            .sorted { $0.totalSeconds > $1.totalSeconds }
    }

    /// Apply tag to all report segments matching a category label and optional hour
    func applyTagToReportSegments(
        category: String,
        hour: Int?,
        grouping: ReportGrouping,
        tagName: String
    ) async -> Int {
        let tz = DisplayTimezoneHelper.preferred
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz

        let matching = allReportSegments.filter { seg in
            guard seg.coverage == .observed else { return false }

            let label: String
            switch grouping {
            case .byApp:
                label = seg.appName.isEmpty ? "(unknown)" : seg.appName
            case .byAppWindow:
                let app = seg.appName.isEmpty ? "(unknown)" : seg.appName
                let title = seg.windowTitle ?? "(no title)"
                label = "\(app) — \(title)"
            case .byTag:
                label = seg.tags.first ?? "(untagged)"
            }
            guard label == category else { return false }

            if let h = hour {
                let startDate = Date(timeIntervalSince1970: Double(seg.startTsUs) / 1_000_000.0)
                return cal.component(.hour, from: startDate) == h
            }
            return true
        }

        for seg in matching {
            let start = Date(timeIntervalSince1970: Double(seg.startTsUs) / 1_000_000.0)
            let end = Date(timeIntervalSince1970: Double(seg.endTsUs) / 1_000_000.0)
            await applyTag(startTime: start, endTime: end, tagName: tagName)
        }

        // Reload reports after tagging
        await loadReports()
        return matching.count
    }

    /// Create a tag and immediately apply it to a segment
    func createTagAndApply(name: String, startTime: Date, endTime: Date) async {
        do {
            let _ = try await xpcClient.createTag(name: name)
            await loadTags()
            await applyTag(startTime: startTime, endTime: endTime, tagName: name)
        } catch {
            errorMessage = "Create+apply tag failed: \(error.localizedDescription)"
        }
    }
}

/// Row for report tables
struct ReportRow: Identifiable {
    let id = UUID()
    let appName: String
    let windowTitle: String?
    let tagName: String?
    let totalSeconds: Double
    let percentage: Double

    var formattedDuration: String {
        let h = Int(totalSeconds) / 3600
        let m = (Int(totalSeconds) % 3600) / 60
        let s = Int(totalSeconds) % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        return "\(s)s"
    }
}

/// Represents a timeline segment for display
struct TimelineSegment: Identifiable {
    let id = UUID()
    let startTime: Date
    let endTime: Date
    let appName: String
    let bundleId: String
    let windowTitle: String?
    let tags: [String]
    let isGap: Bool

    var duration: Foundation.TimeInterval {
        endTime.timeIntervalSince(startTime)
    }
}

/// Represents a tag for display
struct TagItem: Identifiable {
    let id: Int64
    let name: String
    let createdDate: Date
    let isRetired: Bool
}

// MARK: - Timeline Tab

struct TimelineTabView: View {
    @ObservedObject var viewModel: ViewerViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Preset picker
            DateRangePresetPicker(selectedPreset: $viewModel.selectedPreset) { preset in
                Task { await viewModel.applyPreset(preset) }
            }

            Divider()

            // Date navigation + time range filter
            DateNavigationBar(
                selectedDate: $viewModel.selectedDate,
                startTime: $viewModel.startTime,
                endTime: $viewModel.endTime,
                onDateChange: { date in
                    Task {
                        await viewModel.loadTimeline(for: date)
                    }
                },
                onApplyFilter: {
                    Task {
                        viewModel.selectedPreset = .custom
                        await viewModel.loadTimelineForRange()
                    }
                }
            )

            Divider()

            // Timeline content
            if viewModel.isLoading {
                ProgressView("Loading...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.segments.isEmpty {
                EmptyTimelineView()
            } else {
                TimelineListView(segments: viewModel.segments, viewModel: viewModel)
            }

            // Segment count + error
            HStack {
                if !viewModel.segments.isEmpty {
                    Text("\(viewModel.segments.count) segment\(viewModel.segments.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
        .task {
            await viewModel.applyPreset(.today)
        }
    }
}

struct DateNavigationBar: View {
    @Binding var selectedDate: Date
    @Binding var startTime: Date
    @Binding var endTime: Date
    let onDateChange: (Date) -> Void
    let onApplyFilter: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            // Row 1: Date navigation (prev/next day)
            HStack {
                Button(action: previousDay) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)

                DatePicker("", selection: $selectedDate, displayedComponents: .date)
                    .labelsHidden()
                    .onChange(of: selectedDate) { newValue in
                        onDateChange(newValue)
                    }

                Button(action: nextDay) {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .disabled(DisplayTimezoneHelper.calendar.isDateInToday(selectedDate))

                Spacer()

                Button("Today") {
                    selectedDate = Date()
                    onDateChange(Date())
                }
                .disabled(DisplayTimezoneHelper.calendar.isDateInToday(selectedDate))
            }

            // Row 2: Time range pickers + Apply
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Text("From:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    DatePicker("", selection: $startTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }

                HStack(spacing: 4) {
                    Text("To:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    DatePicker("", selection: $endTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }

                Button("Apply") {
                    onApplyFilter()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Spacer()
            }
        }
        .padding()
    }

    private func previousDay() {
        if let newDate = DisplayTimezoneHelper.calendar.date(byAdding: .day, value: -1, to: selectedDate) {
            selectedDate = newDate
            onDateChange(newDate)
        }
    }

    private func nextDay() {
        if let newDate = DisplayTimezoneHelper.calendar.date(byAdding: .day, value: 1, to: selectedDate) {
            selectedDate = newDate
            onDateChange(newDate)
        }
    }
}

/// Reusable date range preset picker bar
struct DateRangePresetPicker: View {
    @Binding var selectedPreset: DateRangePreset
    var onPresetSelected: (DateRangePreset) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(DateRangePreset.allCases) { preset in
                    Button(preset.displayName) {
                        selectedPreset = preset
                        onPresetSelected(preset)
                    }
                    .buttonStyle(.bordered)
                    .tint(selectedPreset == preset ? .accentColor : .secondary)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }
}

struct EmptyTimelineView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No activity recorded")
                .font(.headline)
            Text("Timeline data will appear here when the agent is running.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct TimelineListView: View {
    let segments: [TimelineSegment]
    @ObservedObject var viewModel: ViewerViewModel
    @State private var showingNewTagSheet = false
    @State private var newTagName: String = ""
    @State private var pendingTagSegment: TimelineSegment?

    var body: some View {
        List(segments) { segment in
            TimelineRow(segment: segment, tags: segment.tags)
                .contextMenu {
                    Button(role: .destructive) {
                        Task {
                            await viewModel.deleteRange(
                                startTime: segment.startTime,
                                endTime: segment.endTime
                            )
                        }
                    } label: {
                        Label("Delete Segment", systemImage: "trash")
                    }

                    Divider()

                    Menu("Apply Tag") {
                        let activeTags = viewModel.tags.filter { !$0.isRetired }

                        if activeTags.isEmpty {
                            Text("No tags — create one below")
                                .foregroundColor(.secondary)
                        }

                        ForEach(activeTags) { tag in
                            Button(tag.name) {
                                Task {
                                    await viewModel.applyTag(
                                        startTime: segment.startTime,
                                        endTime: segment.endTime,
                                        tagName: tag.name
                                    )
                                }
                            }
                        }

                        if !activeTags.isEmpty { Divider() }

                        Button("New Tag\u{2026}") {
                            pendingTagSegment = segment
                            newTagName = ""
                            showingNewTagSheet = true
                        }
                    }

                    if !segment.tags.isEmpty {
                        Menu("Remove Tag") {
                            ForEach(segment.tags, id: \.self) { tagName in
                                Button(tagName) {
                                    Task {
                                        await viewModel.removeTag(
                                            startTime: segment.startTime,
                                            endTime: segment.endTime,
                                            tagName: tagName
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
        }
        .task {
            await viewModel.loadTags()
        }
        .sheet(isPresented: $showingNewTagSheet) {
            CreateTagSheet(
                tagName: $newTagName,
                isPresented: $showingNewTagSheet,
                onCreate: { name in
                    guard let seg = pendingTagSegment else { return }
                    Task {
                        await viewModel.createTagAndApply(
                            name: name,
                            startTime: seg.startTime,
                            endTime: seg.endTime
                        )
                    }
                }
            )
        }
    }
}

struct TimelineRow: View {
    let segment: TimelineSegment
    let tags: [String]

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(segment.appName)
                    .font(.headline)
                if let title = segment.windowTitle {
                    Text(title)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                // Show tags if present
                if !tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.2))
                                .cornerRadius(4)
                        }
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(timeRange)
                    .font(.system(.caption, design: .monospaced))
                Text(formattedDuration)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
        .opacity(segment.isGap ? 0.5 : 1.0)
    }

    private var timeRange: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.timeZone = DisplayTimezoneHelper.preferred
        return "\(formatter.string(from: segment.startTime)) – \(formatter.string(from: segment.endTime))"
    }

    private var formattedDuration: String {
        let minutes = Int(segment.duration / 60)
        if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m"
        }
        return "\(minutes)m"
    }
}

// MARK: - Tags Tab

struct TagsTabView: View {
    @ObservedObject var viewModel: ViewerViewModel
    @State private var newTagName: String = ""
    @State private var showingCreateSheet: Bool = false

    var body: some View {
        VStack {
            // Toolbar
            HStack {
                Button("Create Tag") {
                    newTagName = ""
                    showingCreateSheet = true
                }
                Spacer()
            }
            .padding()

            Divider()

            // Tags list
            if viewModel.tags.isEmpty {
                EmptyTagsView()
            } else {
                List(viewModel.tags) { tag in
                    TagRow(tag: tag, onRetire: {
                        Task {
                            await viewModel.retireTag(name: tag.name)
                        }
                    })
                }
            }
        }
        .sheet(isPresented: $showingCreateSheet) {
            CreateTagSheet(
                tagName: $newTagName,
                isPresented: $showingCreateSheet,
                onCreate: { name in
                    Task {
                        await viewModel.createTag(name: name)
                    }
                }
            )
        }
        .task {
            await viewModel.loadTags()
        }
    }
}

struct EmptyTagsView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tag")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No tags defined")
                .font(.headline)
            Text("Create tags to categorize your work.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TagRow: View {
    let tag: TagItem
    var onRetire: (() -> Void)?

    var body: some View {
        HStack {
            Label(tag.name, systemImage: "tag.fill")
            Spacer()
            if tag.isRetired {
                Text("Retired")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if let onRetire = onRetire {
                Button(action: onRetire) {
                    Text("Retire")
                        .font(.caption)
                        .foregroundColor(.red)
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

struct CreateTagSheet: View {
    @Binding var tagName: String
    @Binding var isPresented: Bool
    var onCreate: ((String) -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Text("Create New Tag")
                .font(.headline)

            TextField("Tag name", text: $tagName)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel") {
                    tagName = ""
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create") {
                    onCreate?(tagName)
                    tagName = ""
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(tagName.isEmpty)
            }
        }
        .padding()
        .frame(width: 300)
    }
}

// MARK: - Exports Tab

struct ExportsTabView: View {
    @ObservedObject var viewModel: ViewerViewModel
    @State private var startDate = Date().addingTimeInterval(-7 * 24 * 60 * 60)
    @State private var endDate = Date()
    @State private var exportPreset: DateRangePreset = .last7Days
    @State private var exportFormat: ExportFormatOption = .csv
    @State private var includeTitles: Bool = true
    @State private var isExporting: Bool = false
    @State private var exportMessage: String?
    @State private var exportMessageIsError: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Preset picker
            DateRangePresetPicker(selectedPreset: $exportPreset) { preset in
                applyExportPreset(preset)
            }

            Divider()

            Form {
                Section("Date Range") {
                    DatePicker("From:", selection: $startDate, displayedComponents: .date)
                        .onChange(of: startDate) { _ in exportPreset = .custom }
                    DatePicker("To:", selection: $endDate, displayedComponents: .date)
                        .onChange(of: endDate) { _ in exportPreset = .custom }
                }

                Section("Format") {
                    Picker("Format:", selection: $exportFormat) {
                        ForEach(ExportFormatOption.allCases) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)

                    Toggle("Include window titles", isOn: $includeTitles)
                }

                Section {
                    HStack {
                        if isExporting {
                            ProgressView()
                                .controlSize(.small)
                        }
                        if let msg = exportMessage {
                            Text(msg)
                                .font(.caption)
                                .foregroundColor(exportMessageIsError ? .red : .green)
                        }
                        Spacer()
                        Button("Export...") {
                            exportData()
                        }
                        .disabled(isExporting || startDate >= endDate)
                    }
                }
            }
            .formStyle(.grouped)
            .padding()
        }
    }

    private func applyExportPreset(_ preset: DateRangePreset) {
        exportPreset = preset
        guard let range = preset.dateRange() else { return }
        startDate = range.start
        endDate = range.end
    }

    private func exportData() {
        let format = exportFormat
        let panel = NSSavePanel()
        panel.allowedContentTypes = format == .csv ?
            [UTType.commaSeparatedText] : [UTType.json]
        panel.canCreateDirectories = true
        let ext = format == .csv ? "csv" : "json"
        panel.nameFieldStringValue = "wwk-export-\(formatDateForFilename(startDate)).\(ext)"
        panel.title = "Export Timeline Data"
        panel.prompt = "Export"

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            exportMessage = "Export cancelled."
            exportMessageIsError = false
            return
        }

        isExporting = true
        exportMessage = nil

        let capturedStartDate = startDate
        let capturedEndDate = endDate
        let capturedIncludeTitles = includeTitles

        Task { @MainActor in
            defer { isExporting = false }

            let startTsUs = Int64(capturedStartDate.timeIntervalSince1970 * 1_000_000)
            let endTsUs = Int64(capturedEndDate.timeIntervalSince1970 * 1_000_000)

            // Load timeline segments
            let segments = await ViewerDatabaseReader.loadTimeline(
                startTsUs: startTsUs,
                endTsUs: endTsUs
            )

            if segments.isEmpty {
                exportMessage = "No data to export for the selected range."
                exportMessageIsError = true
                return
            }

            // Load identity for export headers
            let identityData = await ViewerDatabaseReader.loadIdentity()
            let identity = ReportIdentity(
                machineId: identityData?.machineId ?? "unknown",
                username: identityData?.username ?? NSUserName(),
                uid: identityData?.uid ?? Int(getuid())
            )

            // Generate export content
            let content: String
            switch format {
            case .csv:
                content = CSVExporter.export(
                    segments: segments,
                    identity: identity,
                    includeTitles: capturedIncludeTitles
                )
            case .json:
                content = JSONExporter.export(
                    segments: segments,
                    identity: identity,
                    range: (startUs: startTsUs, endUs: endTsUs),
                    includeTitles: capturedIncludeTitles
                )
            }

            // Write to file
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
                exportMessage = "✅ Exported \(segments.count) segments (\(sizeStr)) → \(url.lastPathComponent)"
                exportMessageIsError = false
            } catch {
                exportMessage = "❌ Export failed: \(error.localizedDescription)"
                exportMessageIsError = true
            }
        }
    }

    private func formatDateForFilename(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

enum ExportFormatOption: String, CaseIterable, Identifiable {
    case csv
    case json

    var id: String { rawValue }

    var displayName: String {
        rawValue.uppercased()
    }
}

// MARK: - Reports Tab

enum ReportGrouping: String, CaseIterable, Identifiable {
    case byApp = "By Application"
    case byAppWindow = "By App + Window"
    case byTag = "By Tag"

    var id: String { rawValue }
}

enum ReportVisualizationMode: String, CaseIterable, Identifiable {
    case table = "Table"
    case hourlyBar = "Hourly Bar"
    case spaceFill = "Space Fill"
    case gantt = "Timeline"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .table: return "tablecells"
        case .hourlyBar: return "chart.bar.xaxis"
        case .spaceFill: return "cube.fill"
        case .gantt: return "calendar.day.timeline.left"
        }
    }
}

struct ReportsTabView: View {
    @ObservedObject var viewModel: ViewerViewModel
    @State private var selectedGrouping: ReportGrouping = .byApp
    @State private var visualizationMode: ReportVisualizationMode = .table
    @State private var tagOperationMessage: String? = nil
    @State private var showingTagAlert: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            DateRangePresetPicker(selectedPreset: $viewModel.reportPreset) { preset in
                Task { await viewModel.applyReportPreset(preset) }
            }

            Divider()

            // Timezone indicator
            HStack {
                Spacer()
                Label(DisplayTimezoneHelper.displayLabel, systemImage: "globe")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.top, 4)

            HStack {
                DatePicker("From:", selection: $viewModel.reportStartTime,
                           displayedComponents: [.date, .hourAndMinute])
                DatePicker("To:", selection: $viewModel.reportEndTime,
                           displayedComponents: [.date, .hourAndMinute])
                Button("Apply") {
                    Task {
                        viewModel.reportPreset = .custom
                        await viewModel.loadReports()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)

            Divider()

            // Grouping + Visualization mode pickers
            HStack(spacing: 12) {
                Picker("Group by", selection: $selectedGrouping) {
                    ForEach(ReportGrouping.allCases) { g in
                        Text(g.rawValue).tag(g)
                    }
                }
                .pickerStyle(.segmented)

                Divider()
                    .frame(height: 20)

                Picker("View", selection: $visualizationMode) {
                    ForEach(ReportVisualizationMode.allCases) { mode in
                        Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)

            // Active filter badge
            if let filterName = viewModel.reportAppFilter {
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        .foregroundColor(.accentColor)
                    Text("Filtered: \(filterName)")
                        .font(.callout)
                        .fontWeight(.medium)
                    Spacer()
                    Button {
                        viewModel.setReportFilter(nil)
                    } label: {
                        Label("Clear Filter", systemImage: "xmark.circle.fill")
                            .font(.callout)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.08))
            }

            if viewModel.isLoadingReports {
                ProgressView("Loading reports…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let data: [ReportRow] = {
                    switch selectedGrouping {
                    case .byApp: return viewModel.reportByApp
                    case .byAppWindow: return viewModel.reportByAppWindow
                    case .byTag: return viewModel.reportByTag
                    }
                }()

                let hasSegments = !viewModel.reportSegments.isEmpty

                if data.isEmpty && !hasSegments {
                    VStack(spacing: 12) {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("No data for selected range")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    switch visualizationMode {
                    case .table:
                        ReportsChartView(data: data, grouping: selectedGrouping)
                            .frame(minHeight: 280, idealHeight: 320)
                            .padding()

                        Divider()

                        ReportsTableView(data: data, grouping: selectedGrouping)

                    case .hourlyBar:
                        HourlyBarChartView(
                            segments: viewModel.reportSegments,
                            grouping: selectedGrouping,
                            tags: viewModel.tags,
                            onFilterApp: { appName in
                                viewModel.setReportFilter(appName)
                            },
                            onApplyTag: { category, hour, tagName in
                                Task {
                                    let count = await viewModel.applyTagToReportSegments(
                                        category: category,
                                        hour: hour,
                                        grouping: selectedGrouping,
                                        tagName: tagName
                                    )
                                    tagOperationMessage = "Tagged \(count) segment(s) with '\(tagName)'"
                                    showingTagAlert = true
                                }
                            }
                        )
                        .padding()

                    case .spaceFill:
                        SpaceFillCubeView(
                            segments: viewModel.reportSegments,
                            grouping: selectedGrouping,
                            tags: viewModel.tags,
                            onFilterApp: { appName in
                                viewModel.setReportFilter(appName)
                            },
                            onApplyTag: { category, tagName in
                                Task {
                                    let count = await viewModel.applyTagToReportSegments(
                                        category: category,
                                        hour: nil,
                                        grouping: selectedGrouping,
                                        tagName: tagName
                                    )
                                    tagOperationMessage = "Tagged \(count) segment(s) with '\(tagName)'"
                                    showingTagAlert = true
                                }
                            }
                        )
                        .padding()

                    case .gantt:
                        TimelineGanttView(
                            segments: viewModel.reportSegments,
                            grouping: selectedGrouping,
                            rangeStart: viewModel.reportStartTime,
                            rangeEnd: viewModel.reportEndTime
                        )
                        .padding()
                    }

                    HStack {
                        Spacer()
                        Button("Export CSV…") {
                            exportReportsCSV(data: data, grouping: selectedGrouping)
                        }
                        .padding()
                    }

                    // Motivational footer
                    HStack {
                        Spacer()
                        VStack(spacing: 1) {
                            Text("\"Over time, you spend too much time thinking about what you need to do,")
                            Text("and not doing what you need to do.\"")
                            Text("— Mel Robbins")
                                .fontWeight(.medium)
                        }
                        .font(.caption2)
                        .italic()
                        .foregroundColor(.secondary.opacity(0.7))
                        Spacer()
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .task {
            await viewModel.applyReportPreset(.today)
            await viewModel.loadTags()
        }
        .alert("Tag Applied", isPresented: $showingTagAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(tagOperationMessage ?? "")
        }
    }

    private func exportReportsCSV(data: [ReportRow], grouping: ReportGrouping) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.commaSeparatedText]
        let suffix: String
        switch grouping {
        case .byApp: suffix = "by-app"
        case .byAppWindow: suffix = "by-app-window"
        case .byTag: suffix = "by-tag"
        }
        panel.nameFieldStringValue = "report-\(suffix).csv"
        panel.title = "Export Report CSV"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        var csv = ""
        switch grouping {
        case .byApp:
            csv = "Application,Duration (s),Duration,Percentage\n"
            for row in data {
                csv += "\"\(row.appName)\",\(String(format: "%.1f", row.totalSeconds)),\"\(row.formattedDuration)\",\(String(format: "%.1f%%", row.percentage))\n"
            }
        case .byAppWindow:
            csv = "Application,Window Title,Duration (s),Duration,Percentage\n"
            for row in data {
                csv += "\"\(row.appName)\",\"\(row.windowTitle ?? "(no title)")\",\(String(format: "%.1f", row.totalSeconds)),\"\(row.formattedDuration)\",\(String(format: "%.1f%%", row.percentage))\n"
            }
        case .byTag:
            csv = "Tag,Duration (s),Duration,Percentage\n"
            for row in data {
                csv += "\"\(row.tagName ?? "(untagged)")\",\(String(format: "%.1f", row.totalSeconds)),\"\(row.formattedDuration)\",\(String(format: "%.1f%%", row.percentage))\n"
            }
        }

        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            print("[Reports] CSV export failed: \(error)")
        }
    }
}

struct ReportsChartView: View {
    let data: [ReportRow]
    let grouping: ReportGrouping
    @State private var hoveredLabel: String?

    /// Max hours across visible rows — used to decide whether a bar is wide enough for annotation
    private var maxHours: Double {
        data.prefix(15).map { $0.totalSeconds / 3600.0 }.max() ?? 1.0
    }

    var body: some View {
        VStack(spacing: 4) {
            Chart {
                ForEach(Array(data.prefix(15))) { row in
                    let label = chartLabel(for: row)
                    let hours = row.totalSeconds / 3600.0
                    BarMark(
                        x: .value("Hours", hours),
                        y: .value("Label", label)
                    )
                    .foregroundStyle(by: .value("Category", chartColor(for: row)))
                    .opacity(hoveredLabel == nil || hoveredLabel == label ? 1.0 : 0.4)
                    .annotation(position: .trailing, spacing: 4) {
                        // Only show hours label when bar is ≥10% of the widest bar
                        if hours / maxHours >= 0.10 {
                            Text(String(format: "%.2fh", hours))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // Hover rule line
                if let hLabel = hoveredLabel {
                    RuleMark(y: .value("Label", hLabel))
                        .foregroundStyle(.gray.opacity(0.3))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            .chartXAxisLabel("Hours")
            .chartXAxis {
                AxisMarks(position: .bottom)
            }
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .chartLegend(.hidden)
            .chartOverlay { proxy in
                GeometryReader { _ in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                // location is already in the chart proxy's coordinate space
                                if let label: String = proxy.value(atY: location.y) {
                                    hoveredLabel = label
                                } else {
                                    hoveredLabel = nil
                                }
                            case .ended:
                                hoveredLabel = nil
                            }
                        }
                }
            }
            .overlay(alignment: .topTrailing) {
                // Hover tooltip
                if let hLabel = hoveredLabel,
                   let row = data.prefix(15).first(where: { chartLabel(for: $0) == hLabel }) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hLabel)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        Text("\(row.formattedDuration)  (\(String(format: "%.1f%%", row.percentage)))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .padding(8)
                    .transition(.opacity)
                }
            }

            // Legend below the chart
            chartLegend
        }
    }

    @ViewBuilder
    private var chartLegend: some View {
        let categories = Array(Set(data.prefix(15).map { chartColor(for: $0) })).sorted()
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: min(categories.count, 4))
        LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
            ForEach(categories, id: \.self) { cat in
                HStack(spacing: 4) {
                    Circle()
                        .fill(colorForCategory(cat, in: categories))
                        .frame(width: 8, height: 8)
                    Text(cat)
                        .font(.caption2)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 4)
    }

    private func colorForCategory(_ category: String, in categories: [String]) -> Color {
        if category == "Inactive" { return .gray }
        let palette: [Color] = [.blue, .green, .orange, .purple, .red, .cyan, .yellow, .pink, .mint, .indigo, .brown, .teal]
        guard let idx = categories.firstIndex(of: category) else { return .gray }
        return palette[idx % palette.count]
    }

    private func chartLabel(for row: ReportRow) -> String {
        switch grouping {
        case .byApp: return row.appName
        case .byAppWindow: return "\(row.appName) — \(row.windowTitle ?? "")"
        case .byTag: return row.tagName ?? "(untagged)"
        }
    }

    private func chartColor(for row: ReportRow) -> String {
        grouping == .byTag ? (row.tagName ?? "(untagged)") : row.appName
    }
}

struct ReportsTableView: View {
    let data: [ReportRow]
    let grouping: ReportGrouping

    var body: some View {
        Table(data) {
            TableColumn("Name") { row in
                Text(tableName(for: row))
            }
            .width(min: 120)

            TableColumn("Detail") { row in
                Text(tableDetail(for: row))
                    .foregroundColor(tableDetailColor(for: row))
            }
            .width(min: 160)

            TableColumn("Duration") { row in
                Text(row.formattedDuration)
                    .font(.system(.body, design: .monospaced))
            }
            .width(min: 80, ideal: 100)

            TableColumn("%") { row in
                Text(String(format: "%.1f%%", row.percentage))
                    .font(.system(.body, design: .monospaced))
            }
            .width(min: 50, ideal: 70)
        }
    }

    private func tableName(for row: ReportRow) -> String {
        switch grouping {
        case .byApp, .byAppWindow: return row.appName
        case .byTag: return row.tagName ?? "(untagged)"
        }
    }

    private func tableDetail(for row: ReportRow) -> String {
        switch grouping {
        case .byApp, .byTag: return "—"
        case .byAppWindow: return row.windowTitle ?? "(no title)"
        }
    }

    private func tableDetailColor(for row: ReportRow) -> Color {
        switch grouping {
        case .byApp, .byTag: return .secondary
        case .byAppWindow: return row.windowTitle == nil ? .secondary : .primary
        }
    }
}


// MARK: - Hourly Bar Chart View

/// Data point for the hourly stacked bar chart
private struct HourlyDataPoint: Identifiable {
    let id = UUID()
    let hourLabel: String
    let hour: Int
    let category: String
    let minutes: Double
}

struct HourlyBarChartView: View {
    let segments: [EffectiveSegment]
    let grouping: ReportGrouping
    let tags: [TagItem]
    var onFilterApp: ((String) -> Void)? = nil
    var onApplyTag: ((String, Int?, String) -> Void)? = nil

    @State private var hoveredCategory: String? = nil
    @State private var hoveredHour: Int? = nil

    private var dataPoints: [HourlyDataPoint] {
        let tz = DisplayTimezoneHelper.preferred
        let hourlyGroupBy: Aggregations.HourlyGroupBy = {
            switch grouping {
            case .byApp: return .app
            case .byAppWindow: return .appWindow
            case .byTag: return .tag
            }
        }()
        let raw = Aggregations.totalsByHour(
            segments: segments, timeZone: tz, groupBy: hourlyGroupBy
        )
        return raw.map { entry in
            HourlyDataPoint(
                hourLabel: String(format: "%02d:00", entry.hour),
                hour: entry.hour,
                category: entry.label,
                minutes: entry.seconds / 60.0
            )
        }
    }

    /// Categories present in the hovered hour
    private var categoriesInHoveredHour: [String] {
        guard let h = hoveredHour else { return [] }
        let hourLabel = String(format: "%02d:00", h)
        return Array(Set(dataPoints.filter { $0.hourLabel == hourLabel }.map(\.category))).sorted()
    }

    var body: some View {
        if dataPoints.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)
                Text("No hourly data for selected range")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 4) {
                Chart(dataPoints) { dp in
                    BarMark(
                        x: .value("Hour", dp.hourLabel),
                        y: .value("Minutes", dp.minutes)
                    )
                    .foregroundStyle(by: .value("Category", dp.category))
                    .opacity(hoveredHour == nil || dp.hour == hoveredHour ? 1.0 : 0.4)
                }
                .chartXAxisLabel("Hour of Day")
                .chartYAxisLabel("Minutes")
                .chartLegend(position: .bottom, spacing: 8)
                .frame(minHeight: 300, idealHeight: 400)
                .chartOverlay { proxy in
                    GeometryReader { _ in
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    if let hourLabel: String = proxy.value(atX: location.x) {
                                        hoveredHour = Int(hourLabel.prefix(2))
                                        // Find the closest category by checking Y position
                                        hoveredCategory = categoriesInHoveredHour.first
                                    }
                                case .ended:
                                    hoveredHour = nil
                                    hoveredCategory = nil
                                }
                            }
                    }
                }
                .contextMenu {
                    if let h = hoveredHour {
                        let cats = categoriesInHoveredHour
                        if cats.count == 1, let cat = cats.first {
                            // Single category — direct actions
                            Button {
                                onFilterApp?(cat)
                            } label: {
                                Label("Filter For '\(cat)' Only",
                                      systemImage: "line.3.horizontal.decrease.circle")
                            }

                            Divider()

                            Menu("Apply Tag to '\(cat)' at \(String(format: "%02d", h)):00…") {
                                tagMenuContent(category: cat, hour: h)
                            }
                        } else {
                            // Multiple categories in this hour
                            Menu("Filter For…") {
                                ForEach(cats, id: \.self) { cat in
                                    Button(cat) { onFilterApp?(cat) }
                                }
                            }

                            Divider()

                            Menu("Apply Tag…") {
                                ForEach(cats, id: \.self) { cat in
                                    Menu("\(cat) at \(String(format: "%02d", h)):00") {
                                        tagMenuContent(category: cat, hour: h)
                                    }
                                }
                            }
                        }
                    } else {
                        Text("Right-click on a bar for options")
                            .foregroundColor(.secondary)
                    }
                }

                Text("Stacked by \(grouping.rawValue.lowercased()) · Right-click bars for actions")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func tagMenuContent(category: String, hour: Int) -> some View {
        let activeTags = tags.filter { !$0.isRetired }
        if activeTags.isEmpty {
            Text("No active tags")
                .foregroundColor(.secondary)
        }
        ForEach(activeTags) { tag in
            Button(tag.name) {
                onApplyTag?(category, hour, tag.name)
            }
        }
    }
}


// MARK: - Timeline / Gantt View

/// Data point for Gantt chart rectangles
private struct GanttDataPoint: Identifiable {
    let id = UUID()
    let label: String
    let startDate: Date
    let endDate: Date
    let isGap: Bool
}

struct TimelineGanttView: View {
    let segments: [EffectiveSegment]
    let grouping: ReportGrouping
    let rangeStart: Date
    let rangeEnd: Date

    private var dataPoints: [GanttDataPoint] {
        segments.compactMap { seg -> GanttDataPoint? in
            guard seg.endTsUs > seg.startTsUs else { return nil }
            let start = Date(timeIntervalSince1970: Double(seg.startTsUs) / 1_000_000.0)
            let end = Date(timeIntervalSince1970: Double(seg.endTsUs) / 1_000_000.0)
            let label: String = {
                switch grouping {
                case .byApp:
                    return seg.coverage == .unobservedGap ? "⏸ Gap" :
                        (seg.appName.isEmpty ? "(unknown)" : seg.appName)
                case .byAppWindow:
                    if seg.coverage == .unobservedGap { return "⏸ Gap" }
                    let app = seg.appName.isEmpty ? "(unknown)" : seg.appName
                    let title = seg.windowTitle ?? "(no title)"
                    return "\(app) — \(title)"
                case .byTag:
                    if seg.coverage == .unobservedGap { return "⏸ Gap" }
                    return seg.tags.first ?? "(untagged)"
                }
            }()
            return GanttDataPoint(
                label: label,
                startDate: start,
                endDate: end,
                isGap: seg.coverage == .unobservedGap
            )
        }
    }

    /// Unique labels sorted by first appearance
    private var sortedLabels: [String] {
        var seen: [String: Int] = [:]
        var order: [String] = []
        for dp in dataPoints {
            if seen[dp.label] == nil {
                seen[dp.label] = order.count
                order.append(dp.label)
            }
        }
        return order
    }

    var body: some View {
        let points = dataPoints
        if points.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "calendar.day.timeline.left")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)
                Text("No timeline data for selected range")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                Chart(points) { dp in
                    RectangleMark(
                        xStart: .value("Start", dp.startDate),
                        xEnd: .value("End", dp.endDate),
                        y: .value("App", dp.label)
                    )
                    .foregroundStyle(dp.isGap ? .gray.opacity(0.25) : colorFor(dp.label))
                    .cornerRadius(2)
                }
                .chartXAxis {
                    AxisMarks(values: .automatic) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour().minute())
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .chartXScale(domain: rangeStart...min(rangeEnd, Date()))
                .frame(minHeight: max(200, CGFloat(sortedLabels.count) * 32))
            }
        }
    }

    private let palette: [Color] = [
        .blue, .green, .orange, .purple, .red,
        .cyan, .yellow, .pink, .mint, .indigo,
        .brown, .teal
    ]

    private func colorFor(_ label: String) -> Color {
        if label == "⏸ Gap" { return .gray }
        let labels = sortedLabels.filter { $0 != "⏸ Gap" }
        guard let idx = labels.firstIndex(of: label) else { return .gray }
        return palette[idx % palette.count]
    }
}


// MARK: - Space Fill (Treemap) View

/// Data item for the treemap — one per category
fileprivate struct TreemapItem: Identifiable {
    let id = UUID()
    let label: String
    let seconds: Double
    let color: Color
}

struct SpaceFillCubeView: View {
    let segments: [EffectiveSegment]
    let grouping: ReportGrouping
    let tags: [TagItem]
    var onFilterApp: ((String) -> Void)? = nil
    var onApplyTag: ((String, String) -> Void)? = nil

    private var items: [TreemapItem] {
        var totals: [(label: String, seconds: Double)] = []

        switch grouping {
        case .byApp:
            let byApp = Aggregations.totalsByAppName(segments: segments)
            totals = byApp.map { ($0.key, $0.value) }
        case .byAppWindow:
            let byAW = Aggregations.totalsByAppNameAndWindow(segments: segments)
            totals = byAW.map { ("\($0.appName) — \($0.windowTitle)", $0.seconds) }
        case .byTag:
            let byTag = Aggregations.totalsByTag(segments: segments)
            totals = byTag.map { ($0.key, $0.value) }
        }

        let sorted = totals.sorted { $0.seconds > $1.seconds }
        let labels = sorted.map(\.label)

        return sorted.enumerated().map { idx, entry in
            TreemapItem(
                label: entry.label,
                seconds: entry.seconds,
                color: colorFor(entry.label, at: idx, labels: labels)
            )
        }
    }

    var body: some View {
        let treeItems = items
        if treeItems.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "cube.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)
                Text("No data for selected range")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 4) {
                GeometryReader { geo in
                    let rects = Self.computeTreemap(
                        items: treeItems, in: CGRect(origin: .zero, size: geo.size)
                    )
                    ZStack {
                        ForEach(Array(zip(treeItems.indices, treeItems)), id: \.1.id) { idx, item in
                            if idx < rects.count {
                                let rect = rects[idx]
                                treemapBlock(item: item, rect: rect)
                            }
                        }
                    }
                }
                .frame(minHeight: 300, idealHeight: 400)

                Text("Sized by duration · \(grouping.rawValue.lowercased()) · Right-click blocks for actions")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func treemapBlock(item: TreemapItem, rect: CGRect) -> some View {
        let hours = item.seconds / 3600.0
        let label = item.label
        RoundedRectangle(cornerRadius: 4)
            .fill(item.color.opacity(0.85))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.primary.opacity(0.15), lineWidth: 1)
            )
            .overlay {
                VStack(spacing: 2) {
                    Text(label)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text(String(format: "%.1fh", hours))
                        .font(.system(.caption2, design: .monospaced))
                }
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 1)
                .padding(4)
            }
            .frame(width: max(0, rect.width - 2), height: max(0, rect.height - 2))
            .position(x: rect.midX, y: rect.midY)
            .contextMenu {
                Button {
                    onFilterApp?(label)
                } label: {
                    Label("Filter For '\(label)' Only",
                          systemImage: "line.3.horizontal.decrease.circle")
                }

                Divider()

                Menu("Apply Tag to '\(label)'…") {
                    let activeTags = tags.filter { !$0.isRetired }
                    if activeTags.isEmpty {
                        Text("No active tags")
                            .foregroundColor(.secondary)
                    }
                    ForEach(activeTags) { tag in
                        Button(tag.name) {
                            onApplyTag?(label, tag.name)
                        }
                    }
                }
            }
            .help("\(label): \(String(format: "%.2f", hours))h")
    }

    /// Squarified treemap layout — returns one CGRect per item
    fileprivate static func computeTreemap(items: [TreemapItem], in bounds: CGRect) -> [CGRect] {
        guard !items.isEmpty else { return [] }
        let total = items.reduce(0.0) { $0 + $1.seconds }
        guard total > 0 else { return items.map { _ in bounds } }

        var rects = [CGRect](repeating: .zero, count: items.count)
        var remaining = bounds

        for i in 0..<items.count {
            let fraction = items[i].seconds / max(total, 1e-9)
            let isLastItem = (i == items.count - 1)

            if isLastItem {
                rects[i] = remaining
            } else if remaining.width >= remaining.height {
                // Split horizontally
                let w = remaining.width * CGFloat(fraction)
                    / CGFloat(items[i...].reduce(0.0) { $0 + $1.seconds } / max(total, 1e-9))
                let clampedW = min(w, remaining.width)
                rects[i] = CGRect(x: remaining.minX, y: remaining.minY,
                                  width: clampedW, height: remaining.height)
                remaining = CGRect(x: remaining.minX + clampedW, y: remaining.minY,
                                   width: remaining.width - clampedW, height: remaining.height)
            } else {
                // Split vertically
                let h = remaining.height * CGFloat(fraction)
                    / CGFloat(items[i...].reduce(0.0) { $0 + $1.seconds } / max(total, 1e-9))
                let clampedH = min(h, remaining.height)
                rects[i] = CGRect(x: remaining.minX, y: remaining.minY,
                                  width: remaining.width, height: clampedH)
                remaining = CGRect(x: remaining.minX, y: remaining.minY + clampedH,
                                   width: remaining.width, height: remaining.height - clampedH)
            }
        }
        return rects
    }

    private let palette: [Color] = [
        .blue, .green, .orange, .purple, .red,
        .cyan, .yellow, .pink, .mint, .indigo,
        .brown, .teal
    ]

    private func colorFor(_ label: String, at idx: Int, labels: [String]) -> Color {
        if label == "Inactive" || label == "(untagged)" { return .gray }
        return palette[idx % palette.count]
    }
}