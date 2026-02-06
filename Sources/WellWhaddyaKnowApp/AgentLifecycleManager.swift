// SPDX-License-Identifier: MIT
// AgentLifecycleManager.swift - SMAppService-based agent lifecycle management

import Foundation
import AppKit
import ServiceManagement

/// Manages the wwkd background agent lifecycle via SMAppService (macOS 13+).
/// Provides registration, status querying, and user-facing status descriptions.
@MainActor
final class AgentLifecycleManager: ObservableObject {

    /// The plist name embedded in Contents/Library/LaunchAgents/
    private static let agentPlistName = "com.daylily.wellwhaddyaknow.agent.plist"

    /// Shared instance for app-wide use
    static let shared = AgentLifecycleManager()

    /// The SMAppService reference for the agent
    private let service: SMAppService

    @Published var statusDescription: String = "Unknown"
    @Published var isRegistered: Bool = false
    @Published var isEnabled: Bool = false
    @Published var requiresApproval: Bool = false

    private init() {
        self.service = SMAppService.agent(plistName: Self.agentPlistName)
        refreshStatus()
    }

    // MARK: - Status

    /// Current SMAppService.Status value
    var currentStatus: SMAppService.Status {
        service.status
    }

    /// Refresh published status properties from SMAppService
    func refreshStatus() {
        let status = service.status
        switch status {
        case .notRegistered:
            statusDescription = "Not registered"
            isRegistered = false
            isEnabled = false
            requiresApproval = false
        case .enabled:
            statusDescription = "Registered and enabled"
            isRegistered = true
            isEnabled = true
            requiresApproval = false
        case .requiresApproval:
            statusDescription = "Registered, requires user approval"
            isRegistered = true
            isEnabled = false
            requiresApproval = true
        case .notFound:
            statusDescription = "Agent plist not found in bundle"
            isRegistered = false
            isEnabled = false
            requiresApproval = false
        @unknown default:
            statusDescription = "Unknown status"
            isRegistered = false
            isEnabled = false
            requiresApproval = false
        }
    }

    // MARK: - Registration

    /// Register the agent as a login item via SMAppService.
    /// - Throws: Error if registration fails
    func register() throws {
        try service.register()
        refreshStatus()
    }

    /// Unregister the agent login item.
    /// - Throws: Error if unregistration fails
    func unregister() throws {
        try service.unregister()
        refreshStatus()
    }

    // MARK: - Convenience

    /// Open System Settings → Login Items so user can toggle the agent
    func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Human-readable status string for diagnostics
    var diagnosticSummary: String {
        """
        Registration: \(statusDescription)
        SMAppService.status: \(statusRawString)
        Plist: \(Self.agentPlistName)
        """
    }

    private var statusRawString: String {
        switch service.status {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }
}

