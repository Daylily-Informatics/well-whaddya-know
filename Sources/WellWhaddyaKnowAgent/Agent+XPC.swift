// SPDX-License-Identifier: MIT
// Agent+XPC.swift - XPC listener implementation for the background agent

import Foundation
import Storage
import XPCProtocol
import CoreModel

// MARK: - Agent Service Implementation

/// Implementation of AgentServiceProtocol that uses the XPCCommandHandler
/// This class provides the async interface for XPC clients
public final class AgentService: AgentServiceProtocol, @unchecked Sendable {

    private let commandHandler: XPCCommandHandler
    private let stateProvider: @Sendable () -> (isWorking: Bool, currentApp: String?, currentTitle: String?, axStatus: AccessibilityStatus)
    private let agentRef: Agent?

    /// Initialize the service with command handler and state provider
    /// - Parameters:
    ///   - commandHandler: The XPC command handler for processing requests
    ///   - stateProvider: A fallback closure for sync state access
    ///   - agentRef: Optional reference to Agent for async state queries
    public init(
        commandHandler: XPCCommandHandler,
        stateProvider: @escaping @Sendable () -> (isWorking: Bool, currentApp: String?, currentTitle: String?, axStatus: AccessibilityStatus),
        agentRef: Agent? = nil
    ) {
        self.commandHandler = commandHandler
        self.stateProvider = stateProvider
        self.agentRef = agentRef
    }

    // MARK: - Status API

    public func getStatus() async throws -> StatusResponse {
        // Query the agent actor directly for current state (async-safe)
        let state: (isWorking: Bool, currentApp: String?, currentTitle: String?, axStatus: AccessibilityStatus)
        if let agent = agentRef {
            state = await agent.getCurrentState()
        } else {
            state = stateProvider()
        }

        return commandHandler.getStatus(
            isWorking: state.isWorking,
            currentApp: state.currentApp,
            currentTitle: state.currentTitle,
            accessibilityStatus: state.axStatus
        )
    }

    // MARK: - Edit Operations

    public func submitDeleteRange(_ request: DeleteRangeRequest) async throws -> Int64 {
        try commandHandler.submitDeleteRange(request)
    }

    public func submitAddRange(_ request: AddRangeRequest) async throws -> Int64 {
        try commandHandler.submitAddRange(request)
    }

    public func submitUndoEdit(targetUeeId: Int64) async throws -> Int64 {
        try commandHandler.submitUndoEdit(targetUeeId: targetUeeId)
    }

    // MARK: - Tag Operations

    public func applyTag(_ request: TagRangeRequest) async throws -> Int64 {
        try commandHandler.applyTag(request)
    }

    public func removeTag(_ request: TagRangeRequest) async throws -> Int64 {
        try commandHandler.removeTag(request)
    }

    public func listTags() async throws -> [TagInfo] {
        try commandHandler.listTags()
    }

    public func createTag(name: String) async throws -> Int64 {
        try commandHandler.createTag(name: name)
    }

    public func retireTag(name: String) async throws {
        try commandHandler.retireTag(name: name)
    }

    // MARK: - Export Operations

    public func exportTimeline(_ request: ExportRequest) async throws {
        try commandHandler.exportTimeline(request)
    }

    // MARK: - Tracking Control

    public func pauseTracking() async throws {
        guard let agent = agentRef else {
            throw XPCError.agentNotRunning
        }
        try await agent.pauseTracking()
    }

    public func resumeTracking() async throws {
        guard let agent = agentRef else {
            throw XPCError.agentNotRunning
        }
        try await agent.resumeTracking()
    }

    // MARK: - Health / Doctor

    public func getHealth() async throws -> HealthStatus {
        try commandHandler.getHealth()
    }

    public func verifyDatabase() async throws {
        try commandHandler.verifyDatabase()
    }
}

// MARK: - Agent Extension for XPC

extension Agent {

    /// Create an AgentService backed by this agent's database connection and state
    /// - Returns: An AgentService that implements AgentServiceProtocol
    public func createService() -> AgentService {
        // Create handler with the database connection
        let handler = XPCCommandHandler(
            connection: connection,
            runId: runId
        )

        // Create a reference to self for the state provider closure
        let agentRef = self

        return AgentService(
            commandHandler: handler,
            stateProvider: {
                // Fallback for sync context - actual state is queried via agent actor
                return (false, nil, nil, .unknown)
            },
            agentRef: agentRef
        )
    }
}

