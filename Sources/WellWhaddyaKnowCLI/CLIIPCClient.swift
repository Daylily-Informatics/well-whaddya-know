// SPDX-License-Identifier: MIT
// CLIIPCClient.swift - IPC client wrapper for CLI commands

import Foundation
import XPCProtocol

/// Wrapper around IPCClient for CLI use with proper error handling
struct CLIIPCClient {
    private let ipcClient: IPCClient
    
    init() {
        self.ipcClient = IPCClient()
    }
    
    /// Check if agent is available (socket exists)
    var isAgentAvailable: Bool {
        ipcClient.isAgentAvailable
    }

    /// Get agent status (for doctor/health checks)
    func getStatus() async throws -> StatusResponse {
        guard isAgentAvailable else {
            throw CLIError.agentNotRunning
        }

        do {
            return try await ipcClient.getStatus()
        } catch let error as IPCClientError {
            throw mapIPCError(error)
        }
    }

    /// Delete a time range - returns the user_edit_event id
    func deleteRange(from: Int64, to: Int64, note: String?) async throws -> Int64 {
        guard isAgentAvailable else {
            throw CLIError.agentNotRunning
        }
        
        do {
            let request = DeleteRangeRequest(
                startTsUs: from,
                endTsUs: to,
                note: note
            )
            return try await ipcClient.deleteRange(request)
        } catch let error as IPCClientError {
            throw mapIPCError(error)
        }
    }
    
    /// Add a manual activity range - returns the user_edit_event id
    func addRange(
        from: Int64,
        to: Int64,
        appName: String,
        bundleId: String?,
        title: String?,
        tags: [String],
        note: String?
    ) async throws -> Int64 {
        guard isAgentAvailable else {
            throw CLIError.agentNotRunning
        }
        
        do {
            let request = AddRangeRequest(
                startTsUs: from,
                endTsUs: to,
                appName: appName,
                bundleId: bundleId,
                title: title,
                tags: tags,
                note: note
            )
            return try await ipcClient.addRange(request)
        } catch let error as IPCClientError {
            throw mapIPCError(error)
        }
    }
    
    /// Undo a previous edit - returns the new user_edit_event id
    func undoEdit(targetUeeId: Int64) async throws -> Int64 {
        guard isAgentAvailable else {
            throw CLIError.agentNotRunning
        }
        
        do {
            return try await ipcClient.undoEdit(targetUeeId: targetUeeId)
        } catch let error as IPCClientError {
            throw mapIPCError(error)
        }
    }
    
    /// Apply a tag to a time range - returns the user_edit_event id
    func applyTag(from: Int64, to: Int64, tagName: String) async throws -> Int64 {
        guard isAgentAvailable else {
            throw CLIError.agentNotRunning
        }
        
        do {
            let request = TagRangeRequest(
                startTsUs: from,
                endTsUs: to,
                tagName: tagName
            )
            return try await ipcClient.applyTag(request)
        } catch let error as IPCClientError {
            throw mapIPCError(error)
        }
    }
    
    /// Remove a tag from a time range - returns the user_edit_event id
    func removeTag(from: Int64, to: Int64, tagName: String) async throws -> Int64 {
        guard isAgentAvailable else {
            throw CLIError.agentNotRunning
        }
        
        do {
            let request = TagRangeRequest(
                startTsUs: from,
                endTsUs: to,
                tagName: tagName
            )
            return try await ipcClient.removeTag(request)
        } catch let error as IPCClientError {
            throw mapIPCError(error)
        }
    }
    
    /// Create a new tag - returns the tag_id
    func createTag(name: String) async throws -> Int64 {
        guard isAgentAvailable else {
            throw CLIError.agentNotRunning
        }
        
        do {
            return try await ipcClient.createTag(name: name)
        } catch let error as IPCClientError {
            throw mapIPCError(error)
        }
    }
    
    /// Retire a tag
    func retireTag(name: String) async throws {
        guard isAgentAvailable else {
            throw CLIError.agentNotRunning
        }
        
        do {
            try await ipcClient.retireTag(name: name)
        } catch let error as IPCClientError {
            throw mapIPCError(error)
        }
    }
    
    /// Map IPC errors to CLI errors
    private func mapIPCError(_ error: IPCClientError) -> CLIError {
        switch error {
        case .agentNotRunning, .connectionFailed:
            return .agentNotRunning
        case .serverError(let code, let message):
            // Map server error codes to CLI errors
            switch code {
            case IPCErrorCode.tagNotFound:
                return .tagNotFound(name: message)
            case IPCErrorCode.tagAlreadyExists:
                return .tagAlreadyExists(name: message)
            case IPCErrorCode.invalidTimeRange:
                return .invalidTimeRange(message: message)
            case IPCErrorCode.databaseError:
                return .databaseError(message: message)
            default:
                return .databaseError(message: message)
            }
        default:
            return .databaseError(message: error.localizedDescription)
        }
    }
}

