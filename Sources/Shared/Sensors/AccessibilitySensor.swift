// SPDX-License-Identifier: MIT
// AccessibilitySensor.swift - Window title capture via Accessibility API
// Per SPEC.md Section 3.3/3.4

import Foundation
import ApplicationServices

/// Sensor that observes window title changes via macOS Accessibility API.
/// Per SPEC.md Section 3.4:
/// - Uses AXUIElementCreateApplication(pid) to access app
/// - Reads kAXFocusedWindowAttribute and kAXTitleAttribute
/// - Subscribes to AXObserver notifications for title changes
/// - Falls back to 1-second polling if notifications fail
public final class AccessibilitySensor: @unchecked Sendable {
    
    private let handler: any SensorEventHandler
    private var axObserver: AXObserver?
    private var currentPid: pid_t = 0
    private var isPermissionGranted: Bool = false
    private var pollTimer: Timer?
    private var isObserving: Bool = false
    private var lastKnownTitle: String?
    
    /// Lock for thread safety
    private let lock = NSLock()
    
    /// Polling interval per SPEC.md Section 3.3 - 1 second fallback
    private static let pollIntervalSeconds: TimeInterval = 1.0
    
    public init(handler: any SensorEventHandler) {
        self.handler = handler
        self.isPermissionGranted = Self.checkPermission()
    }
    
    deinit {
        stopObserving()
    }
    
    // MARK: - Permission Detection
    
    /// Check if Accessibility permission is granted using AXIsProcessTrustedWithOptions
    public static func checkPermission() -> Bool {
        // Check without prompting
        return AXIsProcessTrusted()
    }
    
    /// Check permission and optionally prompt user
    public static func checkPermissionWithPrompt() -> Bool {
        // Use string literal to avoid Swift 6 concurrency issue with kAXTrustedCheckOptionPrompt
        // The constant value is "AXTrustedCheckOptionPrompt" per Apple documentation
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
    
    /// Get current permission state
    public func hasPermission() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isPermissionGranted
    }
    
    /// Refresh permission state and emit event if changed
    public func refreshPermissionState() {
        let timestamp = Date()
        let monotonicNs = getMonotonicTimeNs()
        let newState = Self.checkPermission()
        
        lock.lock()
        let oldState = isPermissionGranted
        isPermissionGranted = newState
        lock.unlock()
        
        if oldState != newState {
            Task {
                await self.handler.handle(.accessibilityPermissionChanged(
                    granted: newState,
                    timestamp: timestamp,
                    monotonicNs: monotonicNs
                ))
            }
        }
    }
    
    // MARK: - Title Reading
    
    /// Read the current window title for a given PID
    public func readWindowTitle(for pid: pid_t) -> TitleReadResult {
        // Check permission first
        guard Self.checkPermission() else {
            return .noPermission
        }
        
        // Create AXUIElement for the application
        let appElement = AXUIElementCreateApplication(pid)
        
        // Get the focused window
        var focusedWindow: CFTypeRef?
        let windowResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow
        )
        
        if windowResult == .noValue || windowResult == .attributeUnsupported {
            return .noWindow
        }
        
        if windowResult != .success {
            return .error(code: windowResult.rawValue)
        }
        
        guard let window = focusedWindow else {
            return .noWindow
        }
        
        // Get the window title
        var titleValue: CFTypeRef?
        let titleResult = AXUIElementCopyAttributeValue(
            window as! AXUIElement,
            kAXTitleAttribute as CFString,
            &titleValue
        )
        
        if titleResult == .noValue || titleResult == .attributeUnsupported {
            return .notSupported
        }
        
        if titleResult != .success {
            return .error(code: titleResult.rawValue)
        }
        
        guard let title = titleValue as? String else {
            return .noWindow
        }
        
        return .ok(title)
    }
    
    // MARK: - Observation Control

    /// Start observing title changes for a PID
    public func startObserving(forPid pid: pid_t) {
        lock.lock()
        defer { lock.unlock() }

        // Stop any existing observation
        stopObservingInternal()

        currentPid = pid
        isObserving = true

        // Try to set up AX observer
        if !setupAXObserver(for: pid) {
            // Fall back to polling if AX observer fails
            startPollingInternal()
        }
    }

    /// Stop observing title changes
    public func stopObserving() {
        lock.lock()
        defer { lock.unlock() }
        stopObservingInternal()
    }

    private func stopObservingInternal() {
        // Stop polling timer
        pollTimer?.invalidate()
        pollTimer = nil

        // Remove AX observer
        if let observer = axObserver, currentPid != 0 {
            let appElement = AXUIElementCreateApplication(currentPid)
            AXObserverRemoveNotification(observer, appElement, kAXTitleChangedNotification as CFString)
            AXObserverRemoveNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            axObserver = nil
        }

        isObserving = false
        currentPid = 0
        lastKnownTitle = nil
    }

    // MARK: - Working State Control

    /// Notify sensor that working state changed - stops polling when not working
    public func setWorkingState(_ isWorking: Bool) {
        lock.lock()
        defer { lock.unlock() }

        if !isWorking {
            // Immediately stop polling when not working (per SPEC.md Section 3.3)
            pollTimer?.invalidate()
            pollTimer = nil
        } else if isObserving && axObserver == nil {
            // Resume polling if we're observing but using fallback
            startPollingInternal()
        }
    }

    // MARK: - AX Observer Setup

    private func setupAXObserver(for pid: pid_t) -> Bool {
        var observer: AXObserver?

        let callback: AXObserverCallback = { observer, element, notification, refcon in
            guard let refcon = refcon else { return }
            let sensor = Unmanaged<AccessibilitySensor>.fromOpaque(refcon).takeUnretainedValue()
            sensor.handleAXNotification(notification as String)
        }

        let result = AXObserverCreate(pid, callback, &observer)
        guard result == .success, let observer = observer else {
            return false
        }

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        // Register for title changed notification
        var addResult = AXObserverAddNotification(
            observer, appElement, kAXTitleChangedNotification as CFString, refcon
        )
        if addResult != .success && addResult != .notificationAlreadyRegistered {
            return false
        }

        // Register for focused window changed notification
        addResult = AXObserverAddNotification(
            observer, appElement, kAXFocusedWindowChangedNotification as CFString, refcon
        )
        // Don't fail if this one fails - title changed is the primary notification

        // Add to run loop
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.axObserver = observer

        return true
    }

    private func handleAXNotification(_ notification: String) {
        let timestamp = Date()
        let monotonicNs = getMonotonicTimeNs()

        lock.lock()
        let pid = currentPid
        lock.unlock()

        guard pid != 0 else { return }

        let result = readWindowTitle(for: pid)
        let reason: TitleChangeReason = notification == kAXTitleChangedNotification as String
            ? .axTitleChanged
            : .axFocusedWindowChanged

        Task {
            await self.handler.handle(.titleChanged(
                pid: pid,
                result: result,
                reason: reason,
                timestamp: timestamp,
                monotonicNs: monotonicNs
            ))
        }
    }

    // MARK: - Polling Fallback

    private func startPollingInternal() {
        guard pollTimer == nil else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            guard self.isObserving && self.pollTimer == nil else {
                self.lock.unlock()
                return
            }
            self.lock.unlock()

            self.pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollIntervalSeconds, repeats: true) { [weak self] _ in
                self?.pollTitle()
            }
        }
    }

    private func pollTitle() {
        let timestamp = Date()
        let monotonicNs = getMonotonicTimeNs()

        lock.lock()
        let pid = currentPid
        let lastTitle = lastKnownTitle
        lock.unlock()

        guard pid != 0 else { return }

        let result = readWindowTitle(for: pid)

        // Only emit if title changed
        if result.title != lastTitle {
            lock.lock()
            lastKnownTitle = result.title
            lock.unlock()

            Task {
                await self.handler.handle(.titleChanged(
                    pid: pid,
                    result: result,
                    reason: .pollFallback,
                    timestamp: timestamp,
                    monotonicNs: monotonicNs
                ))
            }
        }
    }

    /// Force a poll and emit event (for initial title capture)
    public func pollTitleNow(for pid: pid_t) {
        let timestamp = Date()
        let monotonicNs = getMonotonicTimeNs()
        let result = readWindowTitle(for: pid)

        lock.lock()
        lastKnownTitle = result.title
        lock.unlock()

        Task {
            await self.handler.handle(.titleChanged(
                pid: pid,
                result: result,
                reason: .pollFallback,
                timestamp: timestamp,
                monotonicNs: monotonicNs
            ))
        }
    }
}

