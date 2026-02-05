// SPDX-License-Identifier: MIT
// AccessibilitySensor.swift - Captures window titles via Accessibility API
// Per SPEC.md Section 3.4

import Foundation
import AppKit
import ApplicationServices

/// Sensor that captures window titles using the Accessibility API.
/// Falls back to polling when AX notifications unavailable.
public final class AccessibilitySensor: @unchecked Sendable {
    
    private let handler: any SensorEventHandler
    private var observedPid: pid_t = 0
    private var axObserver: AXObserver?
    private var pollTimer: Timer?
    private var lastKnownTitle: String?
    private var lastKnownPermissionState: Bool?
    
    /// Poll interval in seconds when AX notifications unavailable
    private let pollIntervalSeconds: TimeInterval = 1.0
    
    public init(handler: any SensorEventHandler) {
        self.handler = handler
    }
    
    deinit {
        stopObserving()
    }
    
    // MARK: - Permission Detection
    
    /// Check if accessibility permission is granted
    public func isAccessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }
    
    /// Check accessibility permission and optionally prompt user
    public func checkPermission(prompt: Bool = false) -> Bool {
        if prompt {
            // Use the string value directly to avoid Swift 6 concurrency issues with
            // kAXTrustedCheckOptionPrompt which is declared as mutable in the C header
            let promptKey = "AXTrustedCheckOptionPrompt" as CFString
            let options = [promptKey: true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }
    
    // MARK: - Title Capture
    
    /// Get the current window title for a given PID
    public func getCurrentTitle(for pid: pid_t) -> (title: String?, status: TitleCaptureStatus) {
        guard isAccessibilityGranted() else {
            return (nil, .noPermission)
        }
        
        let app = AXUIElementCreateApplication(pid)
        
        var focusedWindow: CFTypeRef?
        let windowResult = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        
        guard windowResult == .success, let window = focusedWindow else {
            if windowResult == .noValue || windowResult == .attributeUnsupported {
                return (nil, .noWindow)
            }
            if windowResult == .apiDisabled || windowResult == .notImplemented {
                return (nil, .notSupported)
            }
            return (nil, .error)
        }
        
        var titleValue: CFTypeRef?
        let titleResult = AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &titleValue)
        
        guard titleResult == .success, let title = titleValue as? String else {
            if titleResult == .noValue {
                return (nil, .noWindow)
            }
            return (nil, .error)
        }
        
        return (title, .ok)
    }
    
    // MARK: - Observation
    
    /// Start observing title changes for a PID
    public func startObserving(pid: pid_t) {
        stopObserving()
        observedPid = pid
        
        // Check permission first
        let granted = isAccessibilityGranted()
        if granted != lastKnownPermissionState {
            lastKnownPermissionState = granted
            emitPermissionChange(granted: granted)
        }
        
        guard granted else {
            // Start poll timer to periodically check permission
            startPollTimer()
            return
        }
        
        // Try to set up AX observer
        if !setupAXObserver(for: pid) {
            // Fall back to polling
            startPollTimer()
        }
        
        // Emit initial title
        emitCurrentTitle(source: .startupProbe)
    }
    
    /// Stop observing
    public func stopObserving() {
        pollTimer?.invalidate()
        pollTimer = nil
        
        if let observer = axObserver {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
            axObserver = nil
        }
        
        observedPid = 0
        lastKnownTitle = nil
    }
    
    // MARK: - Private Methods
    
    private func setupAXObserver(for pid: pid_t) -> Bool {
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon = refcon else { return }
            let sensor = Unmanaged<AccessibilitySensor>.fromOpaque(refcon).takeUnretainedValue()
            
            let notificationStr = notification as String
            let source: SensorSource = notificationStr.contains("Title") ? .workspaceNotification : .workspaceNotification
            sensor.emitCurrentTitle(source: source)
        }
        
        let result = AXObserverCreate(pid, callback, &observer)
        guard result == .success, let obs = observer else {
            return false
        }
        
        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        
        // Subscribe to title and focus changes
        AXObserverAddNotification(obs, app, kAXTitleChangedNotification as CFString, refcon)
        AXObserverAddNotification(obs, app, kAXFocusedWindowChangedNotification as CFString, refcon)
        
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        axObserver = obs

        return true
    }

    private func startPollTimer() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollIntervalSeconds, repeats: true) { [weak self] _ in
            self?.pollTimerFired()
        }
    }

    private func pollTimerFired() {
        let granted = isAccessibilityGranted()

        // Check if permission changed
        if granted != lastKnownPermissionState {
            lastKnownPermissionState = granted
            emitPermissionChange(granted: granted)

            if granted && observedPid != 0 {
                // Permission just granted - try to set up AX observer
                if setupAXObserver(for: observedPid) {
                    pollTimer?.invalidate()
                    pollTimer = nil
                }
            }
        }

        if granted {
            emitCurrentTitle(source: .timerPoll)
        }
    }

    private func emitCurrentTitle(source: SensorSource) {
        guard observedPid != 0 else { return }

        let timestamp = Date()
        let monotonicNs = getMonotonicTimeNs()
        let (title, status) = getCurrentTitle(for: observedPid)

        // Only emit if title changed
        if title != lastKnownTitle || source == .startupProbe {
            lastKnownTitle = title

            Task { [weak self] in
                await self?.handler.handle(.titleChanged(
                    pid: self?.observedPid ?? 0,
                    title: title,
                    status: status,
                    source: source,
                    timestamp: timestamp,
                    monotonicNs: monotonicNs
                ))
            }
        }
    }

    private func emitPermissionChange(granted: Bool) {
        let timestamp = Date()
        let monotonicNs = getMonotonicTimeNs()

        Task { [weak self] in
            await self?.handler.handle(.accessibilityPermissionChanged(
                granted: granted,
                timestamp: timestamp,
                monotonicNs: monotonicNs
            ))
        }
    }
}
