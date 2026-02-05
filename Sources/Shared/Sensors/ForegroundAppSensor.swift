// SPDX-License-Identifier: MIT
// ForegroundAppSensor.swift - Observes foreground app changes

import Foundation
import AppKit

/// Sensor that observes foreground application changes via NSWorkspace.
/// Per SPEC.md Section 3.3.
/// Note: Window title detection via Accessibility API is NOT implemented (stubbed as NULL per task spec).
public final class ForegroundAppSensor: @unchecked Sendable {
    
    private let handler: any SensorEventHandler
    private var appActivatedObserver: NSObjectProtocol?
    
    public init(handler: any SensorEventHandler) {
        self.handler = handler
    }
    
    deinit {
        stopObserving()
    }
    
    /// Get current frontmost application info
    public func getCurrentFrontmostApp() -> (bundleId: String, displayName: String, pid: pid_t)? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        
        let bundleId = app.bundleIdentifier ?? "unknown"
        let displayName = app.localizedName ?? "Unknown"
        let pid = app.processIdentifier
        
        return (bundleId, displayName, pid)
    }
    
    /// Start observing foreground app changes
    public func startObserving() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        
        // didActivateApplication - app came to foreground (SPEC.md 3.3)
        appActivatedObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let timestamp = Date()
            let monotonicNs = getMonotonicTimeNs()
            
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            
            let bundleId = app.bundleIdentifier ?? "unknown"
            let displayName = app.localizedName ?? "Unknown"
            let pid = app.processIdentifier
            
            Task { [weak self] in
                await self?.handler.handle(.appActivated(
                    bundleId: bundleId,
                    displayName: displayName,
                    pid: pid,
                    timestamp: timestamp,
                    monotonicNs: monotonicNs
                ))
            }
        }
    }
    
    /// Stop observing notifications
    public func stopObserving() {
        if let observer = appActivatedObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appActivatedObserver = nil
        }
    }
}

