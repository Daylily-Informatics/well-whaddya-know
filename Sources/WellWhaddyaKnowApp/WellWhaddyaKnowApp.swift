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

        // If a CLI-installed plist manages the agent, don't kill it on GUI quit.
        // launchd will keep it running (or restart it) independently of the app.
        let cliPlistManaged = FileManager.default.fileExists(
            atPath: AgentLifecycleManager.cliPlistPath
        )
        if cliPlistManaged {
            return
        }

        // Stop the background agent (wwkd) gracefully via SIGTERM.
        // The agent handles SIGTERM by stopping sensors, emitting agent_stop event,
        // closing the database, removing the IPC socket, and exiting.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-TERM", "-f", "wwkd"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()

        // Belt-and-suspenders: remove IPC socket if agent didn't clean up in time
        let socketPath = getIPCSocketPath()
        if FileManager.default.fileExists(atPath: socketPath) {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
    }
}

