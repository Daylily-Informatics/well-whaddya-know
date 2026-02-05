// SPDX-License-Identifier: MIT
// XPCClient.swift - IPC connection to background agent

import Foundation
import XPCProtocol

/// Client for communicating with the background agent via Unix domain socket.
/// Provides status polling and today's total calculation.
@MainActor
final class XPCClient: Sendable {
    private let ipcClient: IPCClient

    init() {
        self.ipcClient = IPCClient()
    }

    /// Check if agent socket exists
    var isAgentAvailable: Bool {
        ipcClient.isAgentAvailable
    }

    /// Get the current agent status via IPC.
    /// - Returns: StatusResponse from the agent
    /// - Throws: XPCError.agentNotRunning if connection fails
    func getStatus() async throws -> StatusResponse {
        do {
            return try await ipcClient.getStatus()
        } catch IPCClientError.agentNotRunning {
            throw XPCError.agentNotRunning
        } catch IPCClientError.connectionFailed {
            throw XPCError.agentNotRunning
        } catch {
            // Any other IPC error means agent is effectively unreachable
            throw XPCError.agentNotRunning
        }
    }

    /// Get agent health status
    func getHealth() async throws -> HealthStatus {
        do {
            return try await ipcClient.getHealth()
        } catch IPCClientError.agentNotRunning {
            throw XPCError.agentNotRunning
        } catch {
            // Any other IPC error means agent is effectively unreachable
            throw XPCError.agentNotRunning
        }
    }

    /// Delete a time range
    func deleteRange(_ request: DeleteRangeRequest) async throws -> Int64 {
        try await ipcClient.deleteRange(request)
    }

    /// Add a time range
    func addRange(_ request: AddRangeRequest) async throws -> Int64 {
        try await ipcClient.addRange(request)
    }

    /// Undo an edit
    func undoEdit(targetUeeId: Int64) async throws -> Int64 {
        try await ipcClient.undoEdit(targetUeeId: targetUeeId)
    }

    /// Apply a tag to a time range
    func applyTag(_ request: TagRangeRequest) async throws -> Int64 {
        try await ipcClient.applyTag(request)
    }

    /// Remove a tag from a time range
    func removeTag(_ request: TagRangeRequest) async throws -> Int64 {
        try await ipcClient.removeTag(request)
    }

    /// List all tags
    func listTags() async throws -> [TagInfo] {
        try await ipcClient.listTags()
    }

    /// Create a new tag
    func createTag(name: String) async throws -> Int64 {
        try await ipcClient.createTag(name: name)
    }

    /// Retire a tag
    func retireTag(name: String) async throws {
        try await ipcClient.retireTag(name: name)
    }

    /// Export timeline
    func exportTimeline(_ request: ExportRequest) async throws {
        try await ipcClient.exportTimeline(request)
    }

    /// Get today's total working seconds.
    /// Uses direct read-only database access (doesn't require agent).
    /// - Returns: Total working seconds for today
    func getTodayTotalSeconds() async -> Double {
        await TodayTotalCalculator.calculateTodayTotal()
    }
}
