// SPDX-License-Identifier: MIT
// AgentState.swift - Agent state machine per SPEC.md Section 4

import Foundation

/// The agent's state machine tracking system state.
/// Per SPEC.md Section 4.1-4.2.
public struct AgentState: Sendable, Equatable {
    
    /// True when system is not asleep. Set false on willSleep, true on didWake.
    public var isSystemAwake: Bool
    
    /// True when this session owns the console (not fast-user-switched out).
    /// Derived from CGSessionCopyCurrentDictionary kCGSessionOnConsoleKey.
    public var isSessionOnConsole: Bool
    
    /// True when screen is locked.
    /// Derived from CGSessionCopyCurrentDictionary CGSSessionScreenIsLocked.
    public var isScreenLocked: Bool
    
    /// The derived working state per SPEC.md Section 4.2:
    /// isWorking = isSystemAwake && isSessionOnConsole && !isScreenLocked
    public var isWorking: Bool {
        isSystemAwake && isSessionOnConsole && !isScreenLocked
    }
    
    /// Create a new agent state
    public init(isSystemAwake: Bool, isSessionOnConsole: Bool, isScreenLocked: Bool) {
        self.isSystemAwake = isSystemAwake
        self.isSessionOnConsole = isSessionOnConsole
        self.isScreenLocked = isScreenLocked
    }
    
    /// Conservative initial state: assume not working until we probe
    public static var initial: AgentState {
        AgentState(isSystemAwake: true, isSessionOnConsole: false, isScreenLocked: true)
    }
    
    /// Create state from session probe result
    public static func fromSessionState(_ session: SessionState, isSystemAwake: Bool) -> AgentState {
        AgentState(
            isSystemAwake: isSystemAwake,
            isSessionOnConsole: session.isOnConsole,
            isScreenLocked: session.isScreenLocked
        )
    }
}

/// Event kinds for system_state_events table
public enum SystemStateEventKind: String, Sendable {
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

/// Reasons for raw_activity_events
public enum ActivityEventReason: String, Sendable {
    case workingBegan = "working_began"
    case appActivated = "app_activated"
    case axTitleChanged = "ax_title_changed"
    case axFocusedWindowChanged = "ax_focused_window_changed"
    case pollFallback = "poll_fallback"
}

/// Title status for raw_activity_events
public enum TitleStatus: String, Sendable {
    case ok = "ok"
    case noPermission = "no_permission"
    case notSupported = "not_supported"
    case noWindow = "no_window"
    case error = "error"
}

// Import Sensors to use SessionState
import Sensors

