// SPDX-License-Identifier: MIT
// AgentServiceProtocol.swift - XPC service protocol for agent communication

import Foundation

// MARK: - Agent Service Protocol

/// Protocol defining the XPC service interface for the background agent.
/// All methods are async and can throw XPCError.
/// This protocol is implemented by the agent and called by clients (UI, CLI).
public protocol AgentServiceProtocol: Sendable {

    // MARK: - Status API

    /// Get the current agent status
    /// - Returns: StatusResponse with current working state and context
    func getStatus() async throws -> StatusResponse

    // MARK: - Edit Operations

    /// Submit a delete range edit
    /// - Parameters:
    ///   - request: DeleteRangeRequest with start/end timestamps and optional note
    /// - Returns: The new uee_id of the created edit event
    /// - Throws: XPCError.invalidTimeRange if start >= end
    func submitDeleteRange(_ request: DeleteRangeRequest) async throws -> Int64

    /// Submit an add range edit
    /// - Parameters:
    ///   - request: AddRangeRequest with time range, app info, and optional tags
    /// - Returns: The new uee_id of the created edit event
    /// - Throws: XPCError.invalidTimeRange if start >= end
    func submitAddRange(_ request: AddRangeRequest) async throws -> Int64

    /// Submit an undo edit
    /// - Parameters:
    ///   - targetUeeId: The uee_id of the edit to undo
    /// - Returns: The new uee_id of the created undo event
    /// - Throws: XPCError.undoTargetNotFound if target doesn't exist
    /// - Throws: XPCError.undoTargetAlreadyUndone if target is already undone
    func submitUndoEdit(targetUeeId: Int64) async throws -> Int64

    // MARK: - Tag Operations

    /// Apply a tag to a time range
    /// - Parameters:
    ///   - request: TagRangeRequest with time range and tag name
    /// - Returns: The new uee_id of the created tag event
    /// - Throws: XPCError.tagNotFound if tag doesn't exist
    func applyTag(_ request: TagRangeRequest) async throws -> Int64

    /// Remove a tag from a time range
    /// - Parameters:
    ///   - request: TagRangeRequest with time range and tag name
    /// - Returns: The new uee_id of the created untag event
    /// - Throws: XPCError.tagNotFound if tag doesn't exist
    func removeTag(_ request: TagRangeRequest) async throws -> Int64

    /// List all tags
    /// - Returns: Array of TagInfo for all tags (including retired)
    func listTags() async throws -> [TagInfo]

    /// Create a new tag
    /// - Parameters:
    ///   - name: The tag name (must be non-empty, max 255 chars)
    /// - Returns: The new tag_id
    /// - Throws: XPCError.tagAlreadyExists if tag with name exists
    /// - Throws: XPCError.invalidInput if name is empty or too long
    func createTag(name: String) async throws -> Int64

    /// Retire a tag (mark as inactive)
    /// - Parameters:
    ///   - name: The tag name to retire
    /// - Throws: XPCError.tagNotFound if tag doesn't exist
    func retireTag(name: String) async throws

    // MARK: - Export Operations

    /// Export timeline to file
    /// - Parameters:
    ///   - request: ExportRequest with time range, format, and output path
    /// - Throws: XPCError.invalidTimeRange if start >= end
    /// - Throws: XPCError.exportFailed if file write fails
    func exportTimeline(_ request: ExportRequest) async throws

    // MARK: - Tracking Control

    /// Pause tracking manually (user-initiated)
    func pauseTracking() async throws

    /// Resume tracking after a manual pause
    func resumeTracking() async throws

    // MARK: - Health / Doctor

    /// Get agent health status
    /// - Returns: HealthStatus with DB integrity, permissions, uptime, etc.
    func getHealth() async throws -> HealthStatus

    /// Verify database integrity
    /// - Throws: XPCError.databaseError if integrity check fails
    func verifyDatabase() async throws
}

// MARK: - Input Validation

/// Input validation helpers for XPC requests
public enum XPCInputValidation {
    
    /// Maximum tag name length
    public static let maxTagNameLength = 255
    
    /// Validate a time range
    /// - Parameters:
    ///   - startTsUs: Start timestamp in microseconds
    ///   - endTsUs: End timestamp in microseconds
    /// - Throws: XPCError.invalidTimeRange if invalid
    public static func validateTimeRange(startTsUs: Int64, endTsUs: Int64) throws {
        guard startTsUs > 0 else {
            throw XPCError.invalidTimeRange(message: "Start timestamp must be positive")
        }
        guard endTsUs > 0 else {
            throw XPCError.invalidTimeRange(message: "End timestamp must be positive")
        }
        guard startTsUs < endTsUs else {
            throw XPCError.invalidTimeRange(message: "Start must be less than end")
        }
    }
    
    /// Validate a tag name
    /// - Parameters:
    ///   - name: The tag name to validate
    /// - Throws: XPCError.invalidInput if invalid
    public static func validateTagName(_ name: String) throws {
        guard !name.isEmpty else {
            throw XPCError.invalidInput(message: "Tag name cannot be empty")
        }
        guard name.count <= maxTagNameLength else {
            throw XPCError.invalidInput(message: "Tag name exceeds \(maxTagNameLength) characters")
        }
        // Check for control characters
        let controlCharacters = CharacterSet.controlCharacters
        guard name.unicodeScalars.allSatisfy({ !controlCharacters.contains($0) }) else {
            throw XPCError.invalidInput(message: "Tag name contains control characters")
        }
    }
}

