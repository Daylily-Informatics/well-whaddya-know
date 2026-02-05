// SPDX-License-Identifier: MIT
// SessionStateSensor.swift - Polls CGSessionCopyCurrentDictionary for lock/console state

import Foundation
import CoreGraphics

/// Sensor that polls CGSessionCopyCurrentDictionary for session state.
/// Per SPEC.md Section 3.1 and 4.1-4.3.
public final class SessionStateSensor: @unchecked Sendable {
    
    private let handler: any SensorEventHandler
    private var pollTimer: Timer?
    private var lastState: SessionState?
    private let pollQueue = DispatchQueue(label: "com.wellwhaddyaknow.sessionstate")
    
    public init(handler: any SensorEventHandler) {
        self.handler = handler
    }
    
    /// Probe current session state once (for startup)
    public func probeCurrentState() -> SessionState {
        return querySessionState()
    }
    
    /// Start polling at the specified interval
    public func startPolling(intervalSeconds: TimeInterval) {
        pollQueue.async { [weak self] in
            self?.stopPollingInternal()
            
            let timer = Timer(timeInterval: intervalSeconds, repeats: true) { [weak self] _ in
                self?.pollState()
            }
            RunLoop.current.add(timer, forMode: .common)
            self?.pollTimer = timer
            RunLoop.current.run()
        }
    }
    
    /// Stop polling
    public func stopPolling() {
        pollQueue.async { [weak self] in
            self?.stopPollingInternal()
        }
    }
    
    private func stopPollingInternal() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
    
    private func pollState() {
        let state = querySessionState()
        
        // Only emit if state changed
        if lastState != state {
            lastState = state
            Task {
                await handler.handle(.sessionStateChanged(state, source: .timerPoll))
            }
        }
    }
    
    /// Query CGSessionCopyCurrentDictionary and interpret per SPEC.md Section 4.1-4.3
    private func querySessionState() -> SessionState {
        let timestamp = Date()
        let monotonicNs = getMonotonicTimeNs()

        // Keys from CGSessionCopyCurrentDictionary (documented and semi-documented)
        let onConsoleKey = "kCGSSessionOnConsoleKey"
        let screenLockedKey = "CGSSessionScreenIsLocked"

        guard let cfDict = CGSessionCopyCurrentDictionary(),
              let sessionDict = cfDict as? [String: Any] else {
            // Per SPEC.md 4.3: NULL dictionary means unknown, treat as not working
            return SessionState(
                isOnConsole: false,
                isScreenLocked: true,
                timestamp: timestamp,
                monotonicNs: monotonicNs
            )
        }

        // kCGSessionOnConsoleKey: 1 means on console (SPEC.md 4.1)
        let isOnConsole: Bool
        if let onConsole = sessionDict[onConsoleKey] as? Int {
            isOnConsole = (onConsole == 1)
        } else {
            // Key missing: treat as false (SPEC.md 4.3)
            isOnConsole = false
        }

        // CGSSessionScreenIsLocked: 1 means locked (SPEC.md 4.1)
        let isScreenLocked: Bool
        if let locked = sessionDict[screenLockedKey] as? Int {
            isScreenLocked = (locked == 1)
        } else {
            // Key missing: per SPEC.md 4.1, treat as unlocked ONLY if on console
            // Otherwise unknown defaults to not working (SPEC.md 4.3)
            isScreenLocked = !isOnConsole
        }

        return SessionState(
            isOnConsole: isOnConsole,
            isScreenLocked: isScreenLocked,
            timestamp: timestamp,
            monotonicNs: monotonicNs
        )
    }
}

