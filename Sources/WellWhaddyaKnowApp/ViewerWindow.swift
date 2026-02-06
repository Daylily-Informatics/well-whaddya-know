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

    /// Compute (startOfDay, endOfDay) for this preset relative to now.
    func dateRange() -> (start: Date, end: Date)? {
        let calendar = Calendar.current
        let now = Date()

        switch self {
        case .today:
            return (calendar.startOfDay(for: now), endOfDay(now))
        case .yesterday:
            let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
            return (calendar.startOfDay(for: yesterday), endOfDay(yesterday))
        case .thisWeek:
            let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
            return (weekStart, endOfDay(now))
        case .last7Days:
            let start = calendar.date(byAdding: .day, value: -6, to: now)!
            return (calendar.startOfDay(for: start), endOfDay(now))
        case .thisMonth:
            let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? now
            return (monthStart, endOfDay(now))
        case .last30Days:
            let start = calendar.date(byAdding: .day, value: -29, to: now)!
            return (calendar.startOfDay(for: start), endOfDay(now))
        case .last12Months:
            let start = calendar.date(byAdding: .month, value: -12, to: now)!
            return (calendar.startOfDay(for: start), endOfDay(now))
        case .yearToDate:
            var comps = calendar.dateComponents([.year], from: now)
            comps.month = 1; comps.day = 1
            let yearStart = calendar.date(from: comps) ?? now
            return (yearStart, endOfDay(now))
        case .custom:
            return nil
        }
    }

    private func endOfDay(_ date: Date) -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: date)
        comps.hour = 23; comps.minute = 59; comps.second = 59
        return cal.date(from: comps) ?? date
    }
}

/// View model for the viewer window
@MainActor
final class ViewerViewModel: ObservableObject {
    @Published var selectedDate: Date = Date()
    @Published var startTime: Date = Calendar.current.startOfDay(for: Date())
    @Published var endTime: Date = {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 23; comps.minute = 59; comps.second = 59
        return cal.date(from: comps) ?? Date()
    }()
    @Published var selectedPreset: DateRangePreset = .today
    @Published var segments: [TimelineSegment] = []
    @Published var tags: [TagItem] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    // Reports tab state
    @Published var reportPreset: DateRangePreset = .today
    @Published var reportStartTime: Date = Calendar.current.startOfDay(for: Date())
    @Published var reportEndTime: Date = {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 23; comps.minute = 59; comps.second = 59
        return cal.date(from: comps) ?? Date()
    }()
    @Published var reportByApp: [ReportRow] = []
    @Published var reportByAppWindow: [ReportRow] = []
    @Published var reportByTag: [ReportRow] = []
    @Published var isLoadingReports: Bool = false

    private let xpcClient = XPCClient()

    /// Reset time pickers to full-day range for the given date
    func resetTimeRange(for date: Date) {
        let calendar = Calendar.current
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
            return
        }

        let segments = await ViewerDatabaseReader.loadTimeline(
            startTsUs: startTsUs,
            endTsUs: endTsUs
        )

        // By app
        let byApp = Aggregations.totalsByAppName(segments: segments)
        let totalApp = byApp.values.reduce(0.0, +)
        reportByApp = byApp
            .map { ReportRow(appName: $0.key, windowTitle: nil, tagName: nil,
                             totalSeconds: $0.value,
                             percentage: totalApp > 0 ? $0.value / totalApp * 100 : 0) }
            .sorted { $0.totalSeconds > $1.totalSeconds }

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
                .disabled(Calendar.current.isDateInToday(selectedDate))

                Spacer()

                Button("Today") {
                    selectedDate = Date()
                    onDateChange(Date())
                }
                .disabled(Calendar.current.isDateInToday(selectedDate))
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
        if let newDate = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) {
            selectedDate = newDate
            onDateChange(newDate)
        }
    }

    private func nextDay() {
        if let newDate = Calendar.current.date(byAdding: .day, value: 1, to: selectedDate) {
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

struct ReportsTabView: View {
    @ObservedObject var viewModel: ViewerViewModel
    @State private var selectedGrouping: ReportGrouping = .byApp

    var body: some View {
        VStack(spacing: 0) {
            DateRangePresetPicker(selectedPreset: $viewModel.reportPreset) { preset in
                Task { await viewModel.applyReportPreset(preset) }
            }

            Divider()

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

            Picker("Group by", selection: $selectedGrouping) {
                ForEach(ReportGrouping.allCases) { g in
                    Text(g.rawValue).tag(g)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 6)

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

                if data.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("No data for selected range")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ReportsChartView(data: data, grouping: selectedGrouping)
                        .frame(height: 260)
                        .padding()

                    Divider()

                    ReportsTableView(data: data, grouping: selectedGrouping)

                    HStack {
                        Spacer()
                        Button("Export CSV…") {
                            exportReportsCSV(data: data, grouping: selectedGrouping)
                        }
                        .padding()
                    }
                }
            }
        }
        .task {
            await viewModel.applyReportPreset(.today)
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

    var body: some View {
        Chart {
            ForEach(Array(data.prefix(15))) { row in
                BarMark(
                    x: .value("Hours", row.totalSeconds / 3600.0),
                    y: .value("Label", chartLabel(for: row))
                )
                .foregroundStyle(by: .value("Category", chartColor(for: row)))
            }
        }
        .chartXAxisLabel("Hours")
        .chartLegend(position: .bottom)
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

