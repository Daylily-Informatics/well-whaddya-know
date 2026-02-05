// SPDX-License-Identifier: MIT
// CoreModel.swift - In-memory types mirroring database schema for timeline processing
// These types are used as input to the timeline builder (no SQLite dependency)

import Foundation

// MARK: - Value Types

/// Microseconds since Unix epoch (wall-clock time)
/// Wrapper for type safety
public struct TimestampUTC: Sendable, Equatable, Comparable, Hashable {
    public let microseconds: Int64

    public init(_ microseconds: Int64) {
        self.microseconds = microseconds
    }

    public static func < (lhs: TimestampUTC, rhs: TimestampUTC) -> Bool {
        lhs.microseconds < rhs.microseconds
    }
}

/// Nanoseconds from monotonic clock (mach_absolute_time based)
/// Wrapper for type safety
public struct MonotonicTimestamp: Sendable, Equatable, Comparable, Hashable {
    public let nanoseconds: UInt64

    public init(_ nanoseconds: UInt64) {
        self.nanoseconds = nanoseconds
    }

    public static func < (lhs: MonotonicTimestamp, rhs: MonotonicTimestamp) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }
}

/// Half-open interval [start_us, end_us) with invariant: end > start
/// Throws on construction if invariant violated
public struct TimeRange: Sendable, Equatable, Hashable {
    public let startUs: Int64
    public let endUs: Int64

    public enum Error: Swift.Error {
        case invalidRange(start: Int64, end: Int64)
    }

    /// Create a time range. Throws if end <= start.
    public init(startUs: Int64, endUs: Int64) throws {
        guard endUs > startUs else {
            throw Error.invalidRange(start: startUs, end: endUs)
        }
        self.startUs = startUs
        self.endUs = endUs
    }

    /// Duration in microseconds
    public var durationUs: Int64 {
        endUs - startUs
    }

    /// Duration in seconds
    public var durationSeconds: Double {
        Double(durationUs) / 1_000_000.0
    }
}

// MARK: - Identity

/// Machine/user identity per SPEC.md Section 6.4 identity table
public struct Identity: Sendable, Equatable {
    public let identityId: Int64
    public let machineId: String
    public let username: String
    public let uid: Int
    public let createdTsUs: Int64
    public let appGroupId: String
    public let notes: String?

    public init(
        identityId: Int64 = 1,
        machineId: String,
        username: String,
        uid: Int,
        createdTsUs: Int64,
        appGroupId: String,
        notes: String? = nil
    ) {
        self.identityId = identityId
        self.machineId = machineId
        self.username = username
        self.uid = uid
        self.createdTsUs = createdTsUs
        self.appGroupId = appGroupId
        self.notes = notes
    }
}

// MARK: - Agent Run

/// Agent run record per SPEC.md Section 6.4 agent_runs table
public struct AgentRun: Sendable, Equatable {
    public let runId: String
    public let startedTsUs: Int64
    public let startedMonotonicNs: UInt64
    public let agentVersion: String
    public let osVersion: String
    public let hardwareModel: String?
    public let bootSessionId: String?

    public init(
        runId: String,
        startedTsUs: Int64,
        startedMonotonicNs: UInt64,
        agentVersion: String,
        osVersion: String,
        hardwareModel: String? = nil,
        bootSessionId: String? = nil
    ) {
        self.runId = runId
        self.startedTsUs = startedTsUs
        self.startedMonotonicNs = startedMonotonicNs
        self.agentVersion = agentVersion
        self.osVersion = osVersion
        self.hardwareModel = hardwareModel
        self.bootSessionId = bootSessionId
    }
}

// MARK: - Application

/// Application dimension table entry per SPEC.md Section 6.4 applications table
public struct Application: Sendable, Equatable {
    public let appId: Int64
    public let bundleId: String
    public let displayName: String
    public let firstSeenTsUs: Int64

    public init(
        appId: Int64,
        bundleId: String,
        displayName: String,
        firstSeenTsUs: Int64
    ) {
        self.appId = appId
        self.bundleId = bundleId
        self.displayName = displayName
        self.firstSeenTsUs = firstSeenTsUs
    }
}

// MARK: - Window Title

/// Window title dimension table entry per SPEC.md Section 6.4 window_titles table
public struct WindowTitle: Sendable, Equatable {
    public let titleId: Int64
    public let title: String
    public let firstSeenTsUs: Int64

    public init(
        titleId: Int64,
        title: String,
        firstSeenTsUs: Int64
    ) {
        self.titleId = titleId
        self.title = title
        self.firstSeenTsUs = firstSeenTsUs
    }
}

// MARK: - Tag

/// Tag entry per SPEC.md Section 6.4 tags table
public struct Tag: Sendable, Equatable {
    public let tagId: Int64
    public let name: String
    public let createdTsUs: Int64
    public let retiredTsUs: Int64?  // NULL = active
    public let sortOrder: Int

    public init(
        tagId: Int64,
        name: String,
        createdTsUs: Int64,
        retiredTsUs: Int64? = nil,
        sortOrder: Int = 0
    ) {
        self.tagId = tagId
        self.name = name
        self.createdTsUs = createdTsUs
        self.retiredTsUs = retiredTsUs
        self.sortOrder = sortOrder
    }

    /// Whether this tag is currently active (not retired)
    public var isActive: Bool {
        retiredTsUs == nil
    }
}

// MARK: - System State Event

/// In-memory representation of a system_state_events row
/// Used as input to timeline builder
public struct SystemStateEvent: Sendable, Equatable {
    public let sseId: Int64
    public let runId: String
    public let eventTsUs: Int64
    public let eventMonotonicNs: UInt64
    
    // Observed state snapshot AFTER applying this event
    public let isSystemAwake: Bool
    public let isSessionOnConsole: Bool
    public let isScreenLocked: Bool
    public let isWorking: Bool
    
    public let eventKind: SystemStateEventKind
    public let source: EventSource
    
    public let tzIdentifier: String
    public let tzOffsetSeconds: Int
    
    public let payloadJson: String?
    
    public init(
        sseId: Int64,
        runId: String,
        eventTsUs: Int64,
        eventMonotonicNs: UInt64,
        isSystemAwake: Bool,
        isSessionOnConsole: Bool,
        isScreenLocked: Bool,
        isWorking: Bool,
        eventKind: SystemStateEventKind,
        source: EventSource,
        tzIdentifier: String,
        tzOffsetSeconds: Int,
        payloadJson: String? = nil
    ) {
        self.sseId = sseId
        self.runId = runId
        self.eventTsUs = eventTsUs
        self.eventMonotonicNs = eventMonotonicNs
        self.isSystemAwake = isSystemAwake
        self.isSessionOnConsole = isSessionOnConsole
        self.isScreenLocked = isScreenLocked
        self.isWorking = isWorking
        self.eventKind = eventKind
        self.source = source
        self.tzIdentifier = tzIdentifier
        self.tzOffsetSeconds = tzOffsetSeconds
        self.payloadJson = payloadJson
    }
}

public enum SystemStateEventKind: String, Sendable, Equatable {
    case agentStart = "agent_start"
    case agentStop = "agent_stop"
    case stateChange = "state_change"
    case sleep = "sleep"
    case wake = "wake"
    case poweroff = "poweroff"
    case gapDetected = "gap_detected"
    case clockChange = "clock_change"
    case tzChange = "tz_change"
    case accessibilityDenied = "accessibility_denied"
    case accessibilityGranted = "accessibility_granted"
}

public enum EventSource: String, Sendable, Equatable {
    case startupProbe = "startup_probe"
    case workspaceNotification = "workspace_notification"
    case timerPoll = "timer_poll"
    case iokitPower = "iokit_power"
    case shutdownHook = "shutdown_hook"
    case manual = "manual"
}

// MARK: - Raw Activity Event

/// In-memory representation of a raw_activity_events row
/// Used as input to timeline builder
public struct RawActivityEvent: Sendable, Equatable {
    public let raeId: Int64
    public let runId: String
    public let eventTsUs: Int64
    public let eventMonotonicNs: UInt64
    
    // App attribution
    public let appId: Int64
    public let appBundleId: String
    public let appDisplayName: String
    public let pid: Int32
    
    // Window title (nullable)
    public let titleId: Int64?
    public let windowTitle: String?
    public let titleStatus: TitleStatus
    
    public let reason: ActivityEventReason
    public let isWorking: Bool
    
    public let axErrorCode: Int32?
    public let payloadJson: String?
    
    public init(
        raeId: Int64,
        runId: String,
        eventTsUs: Int64,
        eventMonotonicNs: UInt64,
        appId: Int64,
        appBundleId: String,
        appDisplayName: String,
        pid: Int32,
        titleId: Int64?,
        windowTitle: String?,
        titleStatus: TitleStatus,
        reason: ActivityEventReason,
        isWorking: Bool,
        axErrorCode: Int32? = nil,
        payloadJson: String? = nil
    ) {
        self.raeId = raeId
        self.runId = runId
        self.eventTsUs = eventTsUs
        self.eventMonotonicNs = eventMonotonicNs
        self.appId = appId
        self.appBundleId = appBundleId
        self.appDisplayName = appDisplayName
        self.pid = pid
        self.titleId = titleId
        self.windowTitle = windowTitle
        self.titleStatus = titleStatus
        self.reason = reason
        self.isWorking = isWorking
        self.axErrorCode = axErrorCode
        self.payloadJson = payloadJson
    }
}

public enum TitleStatus: String, Sendable, Equatable {
    case ok = "ok"
    case noPermission = "no_permission"
    case notSupported = "not_supported"
    case noWindow = "no_window"
    case error = "error"
}

public enum ActivityEventReason: String, Sendable, Equatable {
    case workingBegan = "working_began"
    case appActivated = "app_activated"
    case axTitleChanged = "ax_title_changed"
    case axFocusedWindowChanged = "ax_focused_window_changed"
    case pollFallback = "poll_fallback"
}

