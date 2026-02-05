// SPDX-License-Identifier: MIT
// XPCClient.swift - XPC connection to background agent

import Foundation
import XPCProtocol

/// XPC client for communicating with the background agent.
/// Provides status polling and today's total calculation.
@MainActor
final class XPCClient: Sendable {
    private let serviceName: String

    init(serviceName: String = xpcServiceName) {
        self.serviceName = serviceName
    }

    /// Get the current agent status via XPC.
    /// - Returns: StatusResponse from the agent
    /// - Throws: XPCError.agentNotRunning if connection fails
    func getStatus() async throws -> StatusResponse {
        // Create XPC connection to the agent
        let connection = NSXPCConnection(machineServiceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: NSObjectProtocol.self)

        connection.resume()
        defer { connection.invalidate() }

        // For now, return a mock response since the agent XPC server
        // is not yet implemented with proper NSXPCConnection handling.
        // This will be replaced with actual XPC calls when the agent
        // implements NSXPCListenerDelegate.
        
        // TODO: Implement actual XPC call when agent supports it
        // For now, check if agent process is running and return mock data
        throw XPCError.agentNotRunning
    }

    /// Get today's total working seconds.
    /// Uses direct read-only database access (doesn't require agent).
    /// - Returns: Total working seconds for today
    func getTodayTotalSeconds() async -> Double {
        await TodayTotalCalculator.calculateTodayTotal()
    }
}
