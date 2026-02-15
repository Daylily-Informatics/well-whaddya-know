// SPDX-License-Identifier: MIT
// WellWhaddyaKnowApp.swift - Main app entry point for menu bar UI

import SwiftUI
import XPCProtocol

/// Main application entry point for the WellWhaddyaKnow menu bar app.
/// This is a menu bar-only app (LSUIElement = true) with no dock icon.
@main
struct WellWhaddyaKnowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Empty scene - all UI is managed via NSStatusBar in AppDelegate
        Settings {
            EmptyView()
        }
    }
}

/// App delegate that manages the menu bar status item and popover.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize the menu bar controller
        menuBarController = MenuBarController()

        // Observe sleep/wake so the GUI refreshes after the system wakes.
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.menuBarController?.prepareForSleep()
            }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.menuBarController?.refreshAfterWake()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Remove sleep/wake observers
        if let obs = sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }

        // Clean up resources
        menuBarController?.stopPolling()

        // If a CLI-installed plist manages the agent, use launchctl bootout
        // to cleanly stop the launchd service (prevents auto-restart).
        // The plist file is preserved — launchd will re-bootstrap it on next login.
        let cliPlistPath = AgentLifecycleManager.cliPlistPath
        let cliPlistManaged = FileManager.default.fileExists(atPath: cliPlistPath)
        if cliPlistManaged {
            let bootout = Process()
            bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            bootout.arguments = ["bootout", "gui/\(getuid())", cliPlistPath]
            bootout.standardOutput = FileHandle.nullDevice
            bootout.standardError = FileHandle.nullDevice
            try? bootout.run()
            bootout.waitUntilExit()
        }

        // Belt-and-suspenders: also send SIGTERM in case bootout missed it
        // or the agent was launched outside launchd (e.g. dev builds).
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-TERM", "-f", "wwkd"]
        kill.standardOutput = FileHandle.nullDevice
        kill.standardError = FileHandle.nullDevice
        try? kill.run()
        kill.waitUntilExit()

        // Remove IPC socket if agent didn't clean up in time
        let socketPath = getIPCSocketPath()
        if FileManager.default.fileExists(atPath: socketPath) {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
    }
}

