// SPDX-License-Identifier: MIT
// MenuBarController.swift - NSStatusBar management for menu bar UI

import AppKit
import SwiftUI
import XPCProtocol

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
            // Use SF Symbol for menu bar icon
            button.image = NSImage(systemSymbolName: "clock.fill", accessibilityDescription: "WellWhaddyaKnow")
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 320, height: 280)
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

        do {
            let status = try await xpcClient.getStatus()
            self.isWorking = status.isWorking
            self.currentApp = status.currentApp
            self.currentTitle = status.currentTitle
            self.accessibilityStatus = AccessibilityDisplayStatus(from: status.accessibilityStatus as AccessibilityStatus)
            self.agentReachable = true
            self.errorMessage = nil
        } catch {
            self.agentReachable = false
            self.errorMessage = "Agent not running"
            self.isWorking = false
            self.currentApp = nil
            self.currentTitle = nil
            // Keep todayTotalSeconds - it was calculated from database
        }
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func quitApp() {
        NSApplication.shared.terminate(nil)
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

