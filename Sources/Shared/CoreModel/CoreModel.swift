// SPDX-License-Identifier: MIT
// CoreModel.swift - In-memory types mirroring database schema for timeline processing
// These types are used as input to the timeline builder (no SQLite dependency)

import Foundation

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

