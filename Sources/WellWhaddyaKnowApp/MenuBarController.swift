// SPDX-License-Identifier: MIT
// MenuBarController.swift - NSStatusBar management for menu bar UI

import AppKit
import SwiftUI
import XPCProtocol
import SQLite3

/// Manages the menu bar status item and popover display.
/// This is the main controller for the menu bar UI.
@MainActor
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let xpcClient: XPCClient
    private let viewModel: StatusViewModel

    override init() {
        self.xpcClient = XPCClient()
        self.viewModel = StatusViewModel(xpcClient: xpcClient)
        super.init()
        setupStatusItem()
        setupPopover()
        startPolling()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            // Use "knowing eye" SF Symbol — fits the snarky, all-seeing "WellWhaddyaKnow" theme
            button.image = NSImage(systemSymbolName: "eye.fill", accessibilityDescription: "WellWhaddyaKnow")
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 340, height: 420)
        popover?.behavior = .transient
        popover?.animates = true
        popover?.contentViewController = NSHostingController(
            rootView: StatusPopoverView(viewModel: viewModel)
        )
    }

    @objc private func togglePopover() {
        guard let popover = popover, let button = statusItem?.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Refresh status when popover opens
            Task {
                await viewModel.refreshStatus()
            }
        }
    }

    func startPolling() {
        viewModel.startPolling()
    }

    func stopPolling() {
        viewModel.stopPolling()
    }
}

/// A recent activity entry for display in the popover.
struct RecentActivityEntry: Identifiable {
    let id: Int64
    let appName: String
    let windowTitle: String?
    let durationText: String
}

/// View model for the status popover, managing state and XPC communication.
@MainActor
final class StatusViewModel: ObservableObject {
    @Published var isWorking: Bool = false
    @Published var currentApp: String?
    @Published var currentTitle: String?
    @Published var accessibilityStatus: AccessibilityDisplayStatus = .unknown
    @Published var agentReachable: Bool = false
    @Published var todayTotalSeconds: Double = 0
    @Published var errorMessage: String?
    @Published var recentActivity: [RecentActivityEntry] = []

    private let xpcClient: XPCClient
    private var pollingTask: Task<Void, Never>?

    init(xpcClient: XPCClient) {
        self.xpcClient = xpcClient
    }

    func startPolling() {
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStatus()
                try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 seconds
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func refreshStatus() async {
        // Always try to calculate today's total from database (doesn't require agent)
        self.todayTotalSeconds = await xpcClient.getTodayTotalSeconds()

        // Load recent activity from database (doesn't require agent)
        self.recentActivity = Self.loadRecentActivity()

        // Check agent lifecycle status for specific error messaging
        let lifecycle = AgentLifecycleManager.shared
        lifecycle.refreshStatus()

        let socketPath = getIPCSocketPath()
        let socketExists = FileManager.default.fileExists(atPath: socketPath)

        do {
            let status = try await xpcClient.getStatus()
            self.isWorking = status.isWorking
            self.currentApp = status.currentApp
            self.currentTitle = status.currentTitle
            self.accessibilityStatus = AccessibilityDisplayStatus(from: status.accessibilityStatus as AccessibilityStatus)
            self.agentReachable = true
            self.errorMessage = nil

            // Even when agent is reachable, warn about accessibility
            if status.accessibilityStatus == .denied {
                // Not an error per se, but we surface it through accessibilityStatus
            }
        } catch {
            self.agentReachable = false
            self.isWorking = false
            self.currentApp = nil
            self.currentTitle = nil
            // Keep todayTotalSeconds - it was calculated from database

            // Determine specific error reason
            if !lifecycle.isRegistered {
                self.errorMessage = "Agent not registered (open Preferences to register)"
            } else if lifecycle.requiresApproval {
                self.errorMessage = "Agent disabled in System Settings (open Login Items)"
            } else if !socketExists {
                self.errorMessage = "IPC socket missing (restart agent)"
            } else {
                self.errorMessage = "Agent not running (click to start)"
            }
        }
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func openLoginItemsSettings() {
        AgentLifecycleManager.shared.openLoginItemsSettings()
    }

    func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Recent Activity (direct DB read)

    /// Load the 5 most recent raw_activity_events with app name, title, and duration.
    private static func loadRecentActivity() -> [RecentActivityEntry] {
        guard let dbPath = TodayTotalCalculator.databasePath,
              FileManager.default.fileExists(atPath: dbPath) else {
            return []
        }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }

        // Get the last 6 events (we need N+1 to compute durations for the top 5)
        let sql = """
            SELECT rae.rae_id, a.display_name, wt.title, rae.event_ts_us
            FROM raw_activity_events rae
            JOIN applications a ON rae.app_id = a.app_id
            LEFT JOIN window_titles wt ON rae.title_id = wt.title_id
            ORDER BY rae.event_ts_us DESC
            LIMIT 6;
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

        struct RawRow {
            let raeId: Int64
            let appName: String
            let title: String?
            let tsUs: Int64
        }

        var rows: [RawRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let raeId = sqlite3_column_int64(stmt, 0)
            let appName: String
            if let cStr = sqlite3_column_text(stmt, 1) {
                appName = String(cString: cStr)
            } else {
                appName = "Unknown"
            }
            let title: String?
            if sqlite3_column_type(stmt, 2) != SQLITE_NULL, let cStr = sqlite3_column_text(stmt, 2) {
                title = String(cString: cStr)
            } else {
                title = nil
            }
            let tsUs = sqlite3_column_int64(stmt, 3)
            rows.append(RawRow(raeId: raeId, appName: appName, title: title, tsUs: tsUs))
        }

        guard !rows.isEmpty else { return [] }

        // Rows are ordered DESC (newest first). Duration of row[i] = row[i].ts - row[i+1].ts
        // For the newest event (index 0), duration = now - row[0].ts
        var entries: [RecentActivityEntry] = []
        let nowUs = Int64(Date().timeIntervalSince1970 * 1_000_000)

        for i in 0 ..< min(5, rows.count) {
            // For newest event, duration = now - ts; for others, duration = previous_ts - this_ts
            let durationUs: Int64
            if i == 0 {
                durationUs = nowUs - rows[i].tsUs
            } else {
                durationUs = rows[i - 1].tsUs - rows[i].tsUs
            }
            let durationSec = max(0, Double(durationUs) / 1_000_000.0)
            entries.append(RecentActivityEntry(
                id: rows[i].raeId,
                appName: rows[i].appName,
                windowTitle: rows[i].title,
                durationText: formatDuration(durationSec)
            ))
        }

        return entries
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let totalSec = Int(seconds)
        let hours = totalSec / 3600
        let minutes = (totalSec % 3600) / 60
        let secs = totalSec % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else if minutes > 0 {
            return "\(minutes)m \(secs)s"
        }
        return "\(secs)s"
    }
}

/// Accessibility status for display purposes
enum AccessibilityDisplayStatus: Sendable {
    case granted
    case denied
    case unknown

    init(from xpcStatus: AccessibilityStatus) {
        switch xpcStatus {
        case .granted: self = .granted
        case .denied: self = .denied
        case .unknown: self = .unknown
        }
    }
}

