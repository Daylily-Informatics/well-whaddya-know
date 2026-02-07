// SPDX-License-Identifier: MIT
// SensorEvent.swift - In-memory event types emitted by sensors

import Foundation

/// Event source identifier for tracking where state changes originate
public enum SensorSource: String, Sendable {
    case startupProbe = "startup_probe"
    case workspaceNotification = "workspace_notification"
    case timerPoll = "timer_poll"
    case iokitPower = "iokit_power"
    case shutdownHook = "shutdown_hook"
    case manual = "manual"
}

/// Session state from CGSessionCopyCurrentDictionary
public struct SessionState: Sendable, Equatable {
    public let isOnConsole: Bool
    public let isScreenLocked: Bool
    public let timestamp: Date
    public let monotonicNs: UInt64
    
    public init(isOnConsole: Bool, isScreenLocked: Bool, timestamp: Date = Date(), monotonicNs: UInt64 = 0) {
        self.isOnConsole = isOnConsole
        self.isScreenLocked = isScreenLocked
        self.timestamp = timestamp
        self.monotonicNs = monotonicNs
    }
    
    /// Conservative default when CGSession is unavailable
    public static var unknown: SessionState {
        SessionState(isOnConsole: false, isScreenLocked: true)
    }
}

/// Title status for Accessibility API results per SPEC.md Section 6.4
public enum TitleCaptureStatus: String, Sendable {
    case ok = "ok"
    case noPermission = "no_permission"
    case notSupported = "not_supported"
    case noWindow = "no_window"
    case error = "error"
}

/// Events emitted by sensors to the agent
public enum SensorEvent: Sendable {
    // Session state changes
    case sessionStateChanged(SessionState, source: SensorSource)

    // Sleep/wake events
    case willSleep(timestamp: Date, monotonicNs: UInt64)
    case didWake(timestamp: Date, monotonicNs: UInt64)
    case willPowerOff(timestamp: Date, monotonicNs: UInt64)

    // Foreground app changes
    case appActivated(bundleId: String, displayName: String, pid: pid_t, timestamp: Date, monotonicNs: UInt64)

    // Window title changes (from AccessibilitySensor)
    case titleChanged(
        pid: pid_t,
        title: String?,
        status: TitleCaptureStatus,
        source: SensorSource,
        timestamp: Date,
        monotonicNs: UInt64,
        axErrorCode: Int32?
    )

    // Accessibility permission changes
    case accessibilityPermissionChanged(granted: Bool, timestamp: Date, monotonicNs: UInt64)
}

/// Protocol for sensor event handlers
public protocol SensorEventHandler: Sendable {
    func handle(_ event: SensorEvent) async
}

/// Utility for getting monotonic time in nanoseconds
public func getMonotonicTimeNs() -> UInt64 {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    let machTime = mach_absolute_time()
    return machTime * UInt64(info.numer) / UInt64(info.denom)
}

/// Utility for getting current timestamp as microseconds since Unix epoch
public func getCurrentTimestampUs() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1_000_000)
}

