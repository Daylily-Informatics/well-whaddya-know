// SPDX-License-Identifier: MIT
// SleepWakeSensor.swift - Observes sleep/wake/poweroff notifications

import Foundation
import AppKit

/// Sensor that observes NSWorkspace sleep/wake/poweroff notifications.
/// Per SPEC.md Section 3.2.
public final class SleepWakeSensor: @unchecked Sendable {
    
    private let handler: any SensorEventHandler
    private var willSleepObserver: NSObjectProtocol?
    private var didWakeObserver: NSObjectProtocol?
    private var willPowerOffObserver: NSObjectProtocol?
    
    public init(handler: any SensorEventHandler) {
        self.handler = handler
    }
    
    deinit {
        stopObserving()
    }
    
    /// Start observing sleep/wake notifications
    public func startObserving() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        
        // willSleep - system is about to sleep (SPEC.md 3.2)
        willSleepObserver = notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let timestamp = Date()
            let monotonicNs = getMonotonicTimeNs()
            Task { [weak self] in
                await self?.handler.handle(.willSleep(timestamp: timestamp, monotonicNs: monotonicNs))
            }
        }
        
        // didWake - system woke from sleep (SPEC.md 3.2)
        didWakeObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let timestamp = Date()
            let monotonicNs = getMonotonicTimeNs()
            Task { [weak self] in
                await self?.handler.handle(.didWake(timestamp: timestamp, monotonicNs: monotonicNs))
            }
        }
        
        // willPowerOff - system shutdown/logout (SPEC.md 3.2, 5.5.D)
        willPowerOffObserver = notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let timestamp = Date()
            let monotonicNs = getMonotonicTimeNs()
            Task { [weak self] in
                await self?.handler.handle(.willPowerOff(timestamp: timestamp, monotonicNs: monotonicNs))
            }
        }
    }
    
    /// Stop observing notifications
    public func stopObserving() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        
        if let observer = willSleepObserver {
            notificationCenter.removeObserver(observer)
            willSleepObserver = nil
        }
        if let observer = didWakeObserver {
            notificationCenter.removeObserver(observer)
            didWakeObserver = nil
        }
        if let observer = willPowerOffObserver {
            notificationCenter.removeObserver(observer)
            willPowerOffObserver = nil
        }
    }
}

