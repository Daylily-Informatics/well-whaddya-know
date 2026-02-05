// SPDX-License-Identifier: MIT
// Agent+EventHandlers.swift - Event handling methods for the agent

import Foundation
import Sensors

extension Agent {
    
    // MARK: - Session State Changes (SPEC.md Section 5.4)

    func handleSessionStateChange(_ sessionState: SessionState, source: SensorSource) async throws {
        let oldIsWorking = state.isWorking

        // Update state from session probe
        state.isSessionOnConsole = sessionState.isOnConsole
        state.isScreenLocked = sessionState.isScreenLocked

        let newIsWorking = state.isWorking

        // Notify accessibility sensor of working state change
        if oldIsWorking != newIsWorking {
            accessibilitySensor?.setWorkingState(newIsWorking)
        }

        // Only emit if isWorking changed
        if oldIsWorking != newIsWorking {
            let timestampUs = Int64(sessionState.timestamp.timeIntervalSince1970 * 1_000_000)

            try emitSystemStateEvent(
                timestampUs: timestampUs,
                monotonicNs: sessionState.monotonicNs,
                kind: .stateChange,
                source: source
            )

            // If transitioning to working, emit activity event (SPEC.md 5.4)
            if newIsWorking {
                try await emitInitialActivityEvent(timestampUs: timestampUs, monotonicNs: sessionState.monotonicNs)
            }
        }
    }
    
    // MARK: - Sleep/Wake Handling (SPEC.md Section 5.5.C)
    
    func handleWillSleep(timestamp: Date, monotonicNs: UInt64) async throws {
        let timestampUs = Int64(timestamp.timeIntervalSince1970 * 1_000_000)
        
        // On willSleep, end working (SPEC.md 5.5.C)
        state.isSystemAwake = false
        
        try emitSystemStateEvent(
            timestampUs: timestampUs,
            monotonicNs: monotonicNs,
            kind: .sleep,
            source: .workspaceNotification
        )
    }
    
    func handleDidWake(timestamp: Date, monotonicNs: UInt64) async throws {
        let timestampUs = Int64(timestamp.timeIntervalSince1970 * 1_000_000)
        
        // On didWake, system is awake but we need to re-probe lock state
        // Per SPEC.md 5.5.C: don't assume unlocked after wake
        state.isSystemAwake = true
        
        // Re-probe session state (sensor is guaranteed to exist after start())
        if let sessionSensor = sessionSensor {
            let sessionState = sessionSensor.probeCurrentState()
            state.isSessionOnConsole = sessionState.isOnConsole
            state.isScreenLocked = sessionState.isScreenLocked
        }
        
        try emitSystemStateEvent(
            timestampUs: timestampUs,
            monotonicNs: monotonicNs,
            kind: .wake,
            source: .workspaceNotification
        )
        
        // If now working, emit activity event
        if state.isWorking {
            try await emitInitialActivityEvent(timestampUs: timestampUs, monotonicNs: monotonicNs)
        }
    }
    
    // MARK: - Shutdown Handling (SPEC.md Section 5.5.D)
    
    func handleWillPowerOff(timestamp: Date, monotonicNs: UInt64) async throws {
        let timestampUs = Int64(timestamp.timeIntervalSince1970 * 1_000_000)
        
        // Force isWorking = false at this timestamp
        state.isSystemAwake = false
        state.isSessionOnConsole = false
        
        try emitSystemStateEvent(
            timestampUs: timestampUs,
            monotonicNs: monotonicNs,
            kind: .poweroff,
            source: .shutdownHook
        )
        
        // Best-effort flush - close connection to ensure WAL is flushed
        // Note: In production, we might want synchronous = FULL here
        connection.close()
    }
    
    // MARK: - App Activation (SPEC.md Section 5.3)

    func handleAppActivated(bundleId: String, displayName: String, pid: pid_t, timestamp: Date, monotonicNs: UInt64) async throws {
        // Only emit activity events when working (SPEC.md 5.4)
        guard state.isWorking else { return }

        let timestampUs = Int64(timestamp.timeIntervalSince1970 * 1_000_000)

        // Ensure app exists in dimension table
        let appId = try eventWriter.ensureApplication(
            bundleId: bundleId,
            displayName: displayName,
            firstSeenTsUs: timestampUs
        )

        currentAppId = appId
        currentPid = pid

        // Start observing title changes for this app
        accessibilitySensor?.startObserving(forPid: pid)

        // Get initial title if permission granted
        var titleId: Int64? = nil
        var titleStatus = TitleStatus.noWindow
        var axErrorCode: Int32? = nil

        if hasAccessibilityPermission, let sensor = accessibilitySensor {
            let result = sensor.readWindowTitle(for: pid)
            titleStatus = TitleStatus(rawValue: result.status.rawValue) ?? .error
            axErrorCode = result.axErrorCode

            if let title = result.title {
                titleId = try eventWriter.ensureWindowTitle(title: title, firstSeenTsUs: timestampUs)
            }
        } else if !hasAccessibilityPermission {
            titleStatus = .noPermission
        }

        // Emit activity event with title info
        try eventWriter.insertRawActivityEvent(
            eventTsUs: timestampUs,
            eventMonotonicNs: monotonicNs,
            appId: appId,
            pid: pid,
            titleId: titleId,
            titleStatus: titleStatus,
            reason: ActivityEventReason.appActivated,
            isWorking: true,
            axErrorCode: axErrorCode
        )
    }

    // MARK: - Title Changes (SPEC.md Section 3.4)

    func handleTitleChanged(pid: pid_t, result: TitleReadResult, reason: TitleChangeReason, timestamp: Date, monotonicNs: UInt64) async throws {
        // Only emit activity events when working (SPEC.md 5.4)
        guard state.isWorking else { return }

        // Need current app info
        guard let appId = currentAppId else { return }

        let timestampUs = Int64(timestamp.timeIntervalSince1970 * 1_000_000)

        // Convert TitleReadStatus to TitleStatus
        let titleStatus = TitleStatus(rawValue: result.status.rawValue) ?? .error

        // Ensure window title exists if we have one
        var titleId: Int64? = nil
        if let title = result.title {
            titleId = try eventWriter.ensureWindowTitle(title: title, firstSeenTsUs: timestampUs)
        }

        // Map TitleChangeReason to ActivityEventReason
        let activityReason: ActivityEventReason
        switch reason {
        case .axTitleChanged:
            activityReason = .axTitleChanged
        case .axFocusedWindowChanged:
            activityReason = .axFocusedWindowChanged
        case .pollFallback:
            activityReason = .pollFallback
        }

        try eventWriter.insertRawActivityEvent(
            eventTsUs: timestampUs,
            eventMonotonicNs: monotonicNs,
            appId: appId,
            pid: pid,
            titleId: titleId,
            titleStatus: titleStatus,
            reason: activityReason,
            isWorking: true,
            axErrorCode: result.axErrorCode
        )
    }

    // MARK: - Accessibility Permission Changes (SPEC.md Section 5.5.E)

    func handleAccessibilityPermissionChanged(granted: Bool, timestamp: Date, monotonicNs: UInt64) async throws {
        let timestampUs = Int64(timestamp.timeIntervalSince1970 * 1_000_000)

        // Update local state
        hasAccessibilityPermission = granted

        // Emit system_state_event for permission change
        try emitSystemStateEvent(
            timestampUs: timestampUs,
            monotonicNs: monotonicNs,
            kind: granted ? .accessibilityGranted : .accessibilityDenied,
            source: .manual  // Permission changes come from user action in System Preferences
        )
    }
    
    // MARK: - Helper Methods
    
    func emitSystemStateEvent(timestampUs: Int64, monotonicNs: UInt64, kind: SystemStateEventKind, source: SensorSource) throws {
        let tz = TimeZone.current
        
        try eventWriter.insertSystemStateEvent(
            eventTsUs: timestampUs,
            eventMonotonicNs: monotonicNs,
            state: state,
            eventKind: kind,
            source: source,
            tzIdentifier: tz.identifier,
            tzOffsetSeconds: tz.secondsFromGMT()
        )
    }
    
    func emitInitialActivityEvent(timestampUs: Int64, monotonicNs: UInt64) async throws {
        // Get current frontmost app (sensor is guaranteed to exist after start())
        guard let foregroundAppSensor = foregroundAppSensor,
              let appInfo = foregroundAppSensor.getCurrentFrontmostApp() else { return }

        let appId = try eventWriter.ensureApplication(
            bundleId: appInfo.bundleId,
            displayName: appInfo.displayName,
            firstSeenTsUs: timestampUs
        )

        currentAppId = appId
        currentPid = appInfo.pid

        // Start observing title changes for this app
        accessibilitySensor?.startObserving(forPid: appInfo.pid)

        // Get initial title if permission granted
        var titleId: Int64? = nil
        var titleStatus = TitleStatus.noWindow
        var axErrorCode: Int32? = nil

        if hasAccessibilityPermission, let sensor = accessibilitySensor {
            let result = sensor.readWindowTitle(for: appInfo.pid)
            titleStatus = TitleStatus(rawValue: result.status.rawValue) ?? .error
            axErrorCode = result.axErrorCode

            if let title = result.title {
                titleId = try eventWriter.ensureWindowTitle(title: title, firstSeenTsUs: timestampUs)
            }
        } else if !hasAccessibilityPermission {
            titleStatus = .noPermission
        }

        try eventWriter.insertRawActivityEvent(
            eventTsUs: timestampUs,
            eventMonotonicNs: monotonicNs,
            appId: appId,
            pid: appInfo.pid,
            titleId: titleId,
            titleStatus: titleStatus,
            reason: ActivityEventReason.workingBegan,
            isWorking: true,
            axErrorCode: axErrorCode
        )
    }
}

