// SPDX-License-Identifier: MIT
// XPCProtocol.swift - XPC interface definitions per SPEC.md Sections 2.1 and 11.2

import Foundation

// MARK: - XPC Service Name

/// Mach service name for the background agent XPC listener
public let xpcServiceName = "com.daylily.wellwhaddyaknow.agent"

// MARK: - XPC Error Types

/// Errors that can occur during XPC operations
public enum XPCError: Error, Sendable, Equatable {
    case invalidTimeRange(message: String)
    case agentNotRunning
    case tagNotFound(name: String)
    case tagAlreadyExists(name: String)
    case undoTargetNotFound(ueeId: Int64)
    case undoTargetAlreadyUndone(ueeId: Int64)
    case databaseError(message: String)
    case invalidInput(message: String)
    case exportFailed(message: String)
    case permissionDenied(message: String)
}

extension XPCError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidTimeRange(let message):
            return "Invalid time range: \(message)"
        case .agentNotRunning:
            return "Agent is not running"
        case .tagNotFound(let name):
            return "Tag not found: \(name)"
        case .tagAlreadyExists(let name):
            return "Tag already exists: \(name)"
        case .undoTargetNotFound(let ueeId):
            return "Undo target not found: \(ueeId)"
        case .undoTargetAlreadyUndone(let ueeId):
            return "Undo target already undone: \(ueeId)"
        case .databaseError(let message):
            return "Database error: \(message)"
        case .invalidInput(let message):
            return "Invalid input: \(message)"
        case .exportFailed(let message):
            return "Export failed: \(message)"
        case .permissionDenied(let message):
            return "Permission denied: \(message)"
        }
    }
}

// MARK: - Response Types

/// Response from status API
public struct StatusResponse: Sendable, Codable, Equatable {
    public let isWorking: Bool
    public let currentApp: String?
    public let currentTitle: String?
    public let accessibilityStatus: AccessibilityStatus
    public let agentVersion: String
    public let agentUptime: TimeInterval

    public init(
        isWorking: Bool,
        currentApp: String?,
        currentTitle: String?,
        accessibilityStatus: AccessibilityStatus,
        agentVersion: String,
        agentUptime: TimeInterval
    ) {
        self.isWorking = isWorking
        self.currentApp = currentApp
        self.currentTitle = currentTitle
        self.accessibilityStatus = accessibilityStatus
        self.agentVersion = agentVersion
        self.agentUptime = agentUptime
    }
}

/// Accessibility permission status
public enum AccessibilityStatus: String, Sendable, Codable, Equatable {
    case granted = "granted"
    case denied = "denied"
    case unknown = "unknown"
}

/// Tag information
public struct TagInfo: Sendable, Codable, Equatable {
    public let tagId: Int64
    public let tagName: String
    public let isRetired: Bool
    public let createdTsUs: Int64
    public let retiredTsUs: Int64?

    public init(
        tagId: Int64,
        tagName: String,
        isRetired: Bool,
        createdTsUs: Int64,
        retiredTsUs: Int64? = nil
    ) {
        self.tagId = tagId
        self.tagName = tagName
        self.isRetired = isRetired
        self.createdTsUs = createdTsUs
        self.retiredTsUs = retiredTsUs
    }
}

/// Health status response
public struct HealthStatus: Sendable, Codable, Equatable {
    public let isHealthy: Bool
    public let databaseIntegrity: DatabaseIntegrityStatus
    public let accessibilityPermission: AccessibilityStatus
    public let agentUptime: TimeInterval
    public let lastEventTsUs: Int64?
    public let schemaVersion: Int
    public let eventCounts: EventCounts

    public init(
        isHealthy: Bool,
        databaseIntegrity: DatabaseIntegrityStatus,
        accessibilityPermission: AccessibilityStatus,
        agentUptime: TimeInterval,
        lastEventTsUs: Int64?,
        schemaVersion: Int,
        eventCounts: EventCounts
    ) {
        self.isHealthy = isHealthy
        self.databaseIntegrity = databaseIntegrity
        self.accessibilityPermission = accessibilityPermission
        self.agentUptime = agentUptime
        self.lastEventTsUs = lastEventTsUs
        self.schemaVersion = schemaVersion
        self.eventCounts = eventCounts
    }
}

/// Database integrity check result
public enum DatabaseIntegrityStatus: String, Sendable, Codable, Equatable {
    case ok = "ok"
    case corrupted = "corrupted"
    case unknown = "unknown"
}

/// Event counts for health status
public struct EventCounts: Sendable, Codable, Equatable {
    public let systemStateEvents: Int64
    public let rawActivityEvents: Int64
    public let userEditEvents: Int64
    public let tags: Int64

    public init(
        systemStateEvents: Int64,
        rawActivityEvents: Int64,
        userEditEvents: Int64,
        tags: Int64
    ) {
        self.systemStateEvents = systemStateEvents
        self.rawActivityEvents = rawActivityEvents
        self.userEditEvents = userEditEvents
        self.tags = tags
    }
}

// MARK: - Export Types

/// Export format for timeline export
public enum ExportFormat: String, Sendable, Codable, Equatable {
    case csv = "csv"
    case json = "json"
}

/// Identity information for exports
public struct ExportIdentity: Sendable, Codable, Equatable {
    public let machineId: String
    public let username: String
    public let uid: Int

    public init(machineId: String, username: String, uid: Int) {
        self.machineId = machineId
        self.username = username
        self.uid = uid
    }
}

/// Export request parameters
public struct ExportRequest: Sendable, Codable, Equatable {
    public let startTsUs: Int64
    public let endTsUs: Int64
    public let format: ExportFormat
    public let outputPath: String
    public let includeTitles: Bool

    public init(
        startTsUs: Int64,
        endTsUs: Int64,
        format: ExportFormat,
        outputPath: String,
        includeTitles: Bool
    ) {
        self.startTsUs = startTsUs
        self.endTsUs = endTsUs
        self.format = format
        self.outputPath = outputPath
        self.includeTitles = includeTitles
    }
}

// MARK: - Edit Request Types

/// Delete range edit request
public struct DeleteRangeRequest: Sendable, Codable, Equatable {
    public let startTsUs: Int64
    public let endTsUs: Int64
    public let note: String?

    public init(startTsUs: Int64, endTsUs: Int64, note: String? = nil) {
        self.startTsUs = startTsUs
        self.endTsUs = endTsUs
        self.note = note
    }
}

/// Add range edit request
public struct AddRangeRequest: Sendable, Codable, Equatable {
    public let startTsUs: Int64
    public let endTsUs: Int64
    public let appName: String
    public let bundleId: String?
    public let title: String?
    public let tags: [String]
    public let note: String?

    public init(
        startTsUs: Int64,
        endTsUs: Int64,
        appName: String,
        bundleId: String? = nil,
        title: String? = nil,
        tags: [String] = [],
        note: String? = nil
    ) {
        self.startTsUs = startTsUs
        self.endTsUs = endTsUs
        self.appName = appName
        self.bundleId = bundleId
        self.title = title
        self.tags = tags
        self.note = note
    }
}

/// Tag range request (for apply/remove tag)
public struct TagRangeRequest: Sendable, Codable, Equatable {
    public let startTsUs: Int64
    public let endTsUs: Int64
    public let tagName: String

    public init(startTsUs: Int64, endTsUs: Int64, tagName: String) {
        self.startTsUs = startTsUs
        self.endTsUs = endTsUs
        self.tagName = tagName
    }
}

