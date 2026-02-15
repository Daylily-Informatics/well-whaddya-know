// SPDX-License-Identifier: MIT
// AgentLifecycleManager.swift - SMAppService-based agent lifecycle management

import Foundation
import AppKit
import ServiceManagement

/// Manages the wwkd background agent lifecycle via SMAppService (macOS 13+).
/// Provides registration, status querying, and user-facing status descriptions.
///
/// When a CLI-installed plist exists at ~/Library/LaunchAgents/, SMAppService
/// registration is skipped to avoid conflicting launchd label ownership.
@MainActor
final class AgentLifecycleManager: ObservableObject {

    /// The plist name embedded in Contents/Library/LaunchAgents/
    private static let agentPlistName = "com.daylily.wellwhaddyaknow.agent.plist"

    /// The launchd label shared by both SMAppService and CLI plists
    nonisolated static let launchdLabel = "com.daylily.wellwhaddyaknow.agent"

    /// Path to the CLI-installed plist (written by `wwk agent install`)
    nonisolated static var cliPlistPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("\(launchdLabel).plist")
            .path
    }

    /// Shared instance for app-wide use
    static let shared = AgentLifecycleManager()

    /// The SMAppService reference for the agent
    private let service: SMAppService

    @Published var statusDescription: String = "Unknown"
    @Published var isRegistered: Bool = false
    @Published var isEnabled: Bool = false
    @Published var requiresApproval: Bool = false
    @Published var isPlistMissing: Bool = false

    /// True when a CLI-installed plist owns the launchd label.
    /// When true, SMAppService registration is skipped to avoid conflicts.
    @Published var isManagedByCLI: Bool = false

    private init() {
        self.service = SMAppService.agent(plistName: Self.agentPlistName)
        refreshStatus()
    }

    // MARK: - CLI Plist Detection

    /// Check whether a CLI-installed plist exists at ~/Library/LaunchAgents/
    var cliPlistExists: Bool {
        FileManager.default.fileExists(atPath: Self.cliPlistPath)
    }

    // MARK: - Status

    /// Current SMAppService.Status value
    var currentStatus: SMAppService.Status {
        service.status
    }

    /// Refresh published status properties from SMAppService
    func refreshStatus() {
        // Check for CLI plist first — it takes precedence
        isManagedByCLI = cliPlistExists

        if isManagedByCLI {
            statusDescription = "Managed by CLI (wwk agent install)"
            isRegistered = true
            isEnabled = true
            requiresApproval = false
            isPlistMissing = false
            return
        }

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
            statusDescription = "Agent plist not found in bundle (dev build)"
            isRegistered = false
            isEnabled = false
            requiresApproval = false
            isPlistMissing = true
        @unknown default:
            statusDescription = "Unknown status"
            isRegistered = false
            isEnabled = false
            requiresApproval = false
        }
    }

    // MARK: - Registration

    /// Register the agent as a login item via SMAppService.
    /// Skips registration when a CLI-installed plist already owns the label.
    /// - Throws: Error if registration fails
    func register() throws {
        if cliPlistExists {
            // CLI plist owns the label — don't fight it
            refreshStatus()
            return
        }
        try service.register()
        refreshStatus()
    }

    /// Unregister the agent login item.
    /// - Throws: Error if unregistration fails
    func unregister() throws {
        if cliPlistExists {
            // CLI plist owns the label — SMAppService unregister would be a no-op or error
            refreshStatus()
            return
        }
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
        if isManagedByCLI {
            return """
            Registration: Managed by CLI plist
            CLI plist: \(Self.cliPlistPath)
            SMAppService: deferred (CLI plist takes precedence)
            """
        }
        return """
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

