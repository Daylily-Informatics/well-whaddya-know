// SPDX-License-Identifier: MIT
// MenuBarController.swift - NSStatusBar management for menu bar UI

import AppKit
import SwiftUI
import XPCProtocol
import SQLite3
import os.log

private let wwkLog = Logger(subsystem: "com.daylily.wellwhaddyaknow", category: "GUI")

/// Manages the menu bar status item and popover display.
/// This is the main controller for the menu bar UI.
@MainActor
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let xpcClient: XPCClient
    private let viewModel: StatusViewModel
    private var isBlinking = false
    /// The base icon name reflecting current working state (restored after blinks)
    private var baseIconName: String = "eye.slash.fill"
    /// The current icon tint color
    private var currentIconColor: NSColor = .magenta
    private var stateObserverTask: Task<Void, Never>?
    private var workspaceObserver: NSObjectProtocol?

    // MARK: - Icon Color Palette
    private static let workingColor    = NSColor.systemGreen
    private static let pausedColor     = NSColor.systemRed
    private static let unreachableColor = NSColor.magenta

    override init() {
        self.xpcClient = XPCClient()
        self.viewModel = StatusViewModel(xpcClient: xpcClient)
        super.init()
        setupStatusItem()
        setupPopover()
        startPolling()
        startStateObserver()
        startWorkspaceObserver()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            // Start with closed eye (not yet confirmed working)
            button.image = Self.makeIcon(symbolName: baseIconName, color: currentIconColor)
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    /// Create a tinted SF Symbol image for the menu bar.
    private static func makeIcon(symbolName: String, color: NSColor) -> NSImage? {
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "WellWhaddyaKnow") else { return nil }
        let config = NSImage.SymbolConfiguration(paletteColors: [color])
        return image.withSymbolConfiguration(config)
    }

    /// Observe viewModel state changes and update the menu bar icon accordingly.
    private func startStateObserver() {
        stateObserverTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s poll
                guard !Task.isCancelled, let self = self else { break }
                self.updateIconForWorkingState(
                    isWorking: self.viewModel.isWorking,
                    agentReachable: self.viewModel.agentReachable
                )
            }
        }
    }

    /// Update the base icon to reflect working state with tint color.
    /// - eye.fill  (green)   when connected & working
    /// - eye.fill  (red)     when connected & not working (paused / idle)
    /// - eye.slash.fill (magenta) when agent unreachable
    private func updateIconForWorkingState(isWorking: Bool, agentReachable: Bool) {
        let newIcon: String
        let newColor: NSColor
        if !agentReachable {
            newIcon = "eye.slash.fill"
            newColor = Self.unreachableColor
        } else if isWorking {
            newIcon = "eye.fill"
            newColor = Self.workingColor
        } else {
            newIcon = "eye.fill"
            newColor = Self.pausedColor
        }
        guard newIcon != baseIconName || newColor != currentIconColor else { return }
        baseIconName = newIcon
        currentIconColor = newColor
        // Only update the displayed icon if not mid-blink
        if !isBlinking, let button = statusItem?.button {
            button.image = Self.makeIcon(symbolName: baseIconName, color: currentIconColor)
        }
    }

    // MARK: - Workspace Focus Observer

    /// Subscribe to foreground-app changes and trigger a single blink on each switch.
    private func startWorkspaceObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.performSingleBlink()
            }
        }
    }

    private func stopWorkspaceObserver() {
        if let obs = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            workspaceObserver = nil
        }
    }

    // MARK: - Eye Blink Animation

    /// Single blink: grays out the current icon briefly then restores (~400ms).
    /// Triggered ONLY by: (1) active window change, (2) popover open.
    private func performSingleBlink() {
        guard !isBlinking, let button = statusItem?.button else { return }
        isBlinking = true
        button.image = Self.makeIcon(symbolName: baseIconName, color: .systemGray)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000) // 400ms grayed
            guard !Task.isCancelled, let self = self else { return }
            button.image = Self.makeIcon(symbolName: self.baseIconName, color: self.currentIconColor)
            self.isBlinking = false
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
            performSingleBlink()
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
        stopWorkspaceObserver()
        stateObserverTask?.cancel()
        stateObserverTask = nil
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
        // Check agent lifecycle status for specific error messaging
        let lifecycle = AgentLifecycleManager.shared
        lifecycle.refreshStatus()

        let socketPath = getIPCSocketPath()
        let socketExists = FileManager.default.fileExists(atPath: socketPath)

        // Determine current working state from agent first so we can
        // pass it to the today-total calculator (avoids counting up to
        // "now" when tracking is paused).
        do {
            let status = try await xpcClient.getStatus()
            let oldIsWorking = self.isWorking
            self.isWorking = status.isWorking
            if oldIsWorking != status.isWorking {
                wwkLog.info("refreshStatus: isWorking changed \(oldIsWorking) → \(status.isWorking)")
            }
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

        // Calculate today's total from database (read-only, doesn't require agent).
        // Uses the just-determined isWorking so the timer stops when paused.
        self.todayTotalSeconds = await xpcClient.getTodayTotalSeconds(isCurrentlyWorking: self.isWorking)

        // Load recent activity from database (doesn't require agent)
        self.recentActivity = Self.loadRecentActivity()
    }

    /// Toggle tracking: pause if working, resume if paused.
    func toggleTracking() async {
        let wasWorking = isWorking
        wwkLog.info("toggleTracking() called, isWorking=\(self.isWorking), agentReachable=\(self.agentReachable)")

        // Pause polling so a concurrent refreshStatus() can't read stale state.
        stopPolling()

        do {
            if isWorking {
                wwkLog.info("Calling pauseTracking()...")
                try await xpcClient.pauseTracking()
                wwkLog.info("pauseTracking() succeeded")
            } else {
                wwkLog.info("Calling resumeTracking()...")
                try await xpcClient.resumeTracking()
                wwkLog.info("resumeTracking() succeeded")
            }
            // Small delay so the agent commits the state_change event before
            // we query it.
            try? await Task.sleep(nanoseconds: 150_000_000) // 150 ms
        } catch {
            wwkLog.error("toggleTracking() CAUGHT ERROR: \(error.localizedDescription)")
            errorMessage = "Failed to toggle tracking: \(error.localizedDescription)"
        }

        // ALWAYS refresh, even if the IPC call threw — ensures UI reflects
        // actual agent state rather than going stale.
        wwkLog.info("Calling refreshStatus() after toggle...")
        await refreshStatus()
        wwkLog.info("refreshStatus() done. isWorking=\(self.isWorking) (was \(wasWorking))")

        // Resume polling.
        startPolling()
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



