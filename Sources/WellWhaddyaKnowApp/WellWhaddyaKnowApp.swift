// SPDX-License-Identifier: MIT
// WellWhaddyaKnowApp.swift - Main app entry point for menu bar UI

import SwiftUI

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
    }
}

