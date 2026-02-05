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
    /// Falls back to 0 if XPC fails or no data available.
    /// - Returns: Total working seconds for today
    func getTodayTotalSeconds() async -> Double {
        // TODO: Implement via XPC or direct read-only DB access
        // For now, return 0 as placeholder
        // 
        // Implementation options:
        // 1. Add getTodayTotal() to AgentServiceProtocol and call via XPC
        // 2. Direct read-only SQLite access using App Group container
        //    - Open DB at ~/Library/Group Containers/group.com.daylily.wellwhaddyaknow/WellWhaddyaKnow/wwk.sqlite
        //    - Query events for today
        //    - Build timeline using TimelineBuilder
        //    - Calculate total using Aggregations.totalWorkingTime()
        //
        // Option 2 is preferred for read-only operations as it doesn't
        // require the agent to be running.
        return 0.0
    }
}
