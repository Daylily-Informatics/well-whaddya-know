// SPDX-License-Identifier: MIT
// ViewerWindow.swift - Viewer/Editor window per SPEC.md Section 9.2

import SwiftUI
import CoreModel
import Timeline
import XPCProtocol

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
    case tags
    case exports

    var id: String { rawValue }

    var title: String {
        switch self {
        case .timeline: return "Timeline"
        case .tags: return "Tags"
        case .exports: return "Exports"
        }
    }

    var icon: String {
        switch self {
        case .timeline: return "clock"
        case .tags: return "tag"
        case .exports: return "square.and.arrow.up"
        }
    }
}

/// View model for the viewer window
@MainActor
final class ViewerViewModel: ObservableObject {
    @Published var selectedDate: Date = Date()
    @Published var segments: [TimelineSegment] = []
    @Published var tags: [TagItem] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private let xpcClient = XPCClient()

    func loadTimeline(for date: Date) async {
        isLoading = true
        defer { isLoading = false }

        // Calculate time range for the selected date (full day)
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            return
        }

        let startTsUs = Int64(startOfDay.timeIntervalSince1970 * 1_000_000)
        let endTsUs = Int64(endOfDay.timeIntervalSince1970 * 1_000_000)

        // Read timeline from database
        let effectiveSegments = await ViewerDatabaseReader.loadTimeline(
            startTsUs: startTsUs,
            endTsUs: endTsUs
        )

        // Convert to display segments
        segments = effectiveSegments.map { seg in
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
            // Date navigation
            DateNavigationBar(
                selectedDate: $viewModel.selectedDate,
                onDateChange: { date in
                    Task {
                        await viewModel.loadTimeline(for: date)
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
                TimelineListView(segments: viewModel.segments)
            }
        }
    }
}

struct DateNavigationBar: View {
    @Binding var selectedDate: Date
    let onDateChange: (Date) -> Void

    var body: some View {
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

    var body: some View {
        List(segments) { segment in
            TimelineRow(segment: segment)
        }
    }
}

struct TimelineRow: View {
    let segment: TimelineSegment

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
                    TagRow(tag: tag)
                }
            }
        }
        .sheet(isPresented: $showingCreateSheet) {
            CreateTagSheet(tagName: $newTagName, isPresented: $showingCreateSheet)
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

    var body: some View {
        HStack {
            Label(tag.name, systemImage: "tag.fill")
            Spacer()
            if tag.isRetired {
                Text("Retired")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct CreateTagSheet: View {
    @Binding var tagName: String
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("Create New Tag")
                .font(.headline)

            TextField("Tag name", text: $tagName)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create") {
                    // TODO: Create tag via XPC
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
    @State private var exportFormat: ExportFormatOption = .csv
    @State private var includeTitles: Bool = true
    @State private var isExporting: Bool = false

    var body: some View {
        Form {
            Section("Date Range") {
                DatePicker("From:", selection: $startDate, displayedComponents: .date)
                DatePicker("To:", selection: $endDate, displayedComponents: .date)
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

    private func exportData() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = exportFormat == .csv ?
            [.commaSeparatedText] : [.json]
        panel.nameFieldStringValue = "wwk-export-\(formatDateForFilename(startDate))"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            // TODO: Perform actual export via CLI or direct database read
            isExporting = false
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

