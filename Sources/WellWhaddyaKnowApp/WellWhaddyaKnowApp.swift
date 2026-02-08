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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize the menu bar controller
        menuBarController = MenuBarController()
    }

    func applicationWillTerminate(_ notification: Notification) {
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

