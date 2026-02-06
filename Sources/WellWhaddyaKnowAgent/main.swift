// SPDX-License-Identifier: MIT
// main.swift - Entry point for the wwkd background agent

import Foundation
import AppKit
import XPCProtocol

/// Global agent reference to keep alive across the async/sync boundary
/// MainActor-isolated for Swift 6 concurrency safety
@MainActor private var agentRef: Agent?

/// IPC server reference to keep alive
@MainActor private var ipcServerRef: IPCServer?

/// Signal sources kept alive (stored to prevent deallocation)
/// MainActor-isolated since they're accessed from main queue handlers
@MainActor private var sigtermSource: DispatchSourceSignal?
@MainActor private var sigintSource: DispatchSourceSignal?

/// Default database path in App Group container (per SPEC.md Section 3)
/// Path: ~/Library/Group Containers/group.com.daylily.wellwhaddyaknow/WellWhaddyaKnow/wwk.sqlite
private func getDefaultDatabasePath() -> String {
    let appGroupId = "group.com.daylily.wellwhaddyaknow"

    // Try the App Group container API first (works in sandboxed apps)
    if let containerURL = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupId
    ) {
        let appDir = containerURL.appendingPathComponent("WellWhaddyaKnow", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("wwk.sqlite").path
    }

    // Fallback: construct the path directly for non-sandboxed command-line tools
    // This matches the path that containerURL would return
    let home = FileManager.default.homeDirectoryForCurrentUser
    let groupContainers = home.appendingPathComponent("Library/Group Containers", isDirectory: true)
    let appDir = groupContainers
        .appendingPathComponent(appGroupId, isDirectory: true)
        .appendingPathComponent("WellWhaddyaKnow", isDirectory: true)

    // Create directory if it doesn't exist
    try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

    return appDir.appendingPathComponent("wwk.sqlite").path
}

/// Set up signal handlers for graceful shutdown
@MainActor
private func setupSignalHandlers() {
    // SIGTERM handler
    let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    sigterm.setEventHandler {
        print("wwkd: Received SIGTERM, shutting down...")
        Task { @MainActor in
            ipcServerRef?.stop()
            try? await agentRef?.stop()
            Foundation.exit(0)
        }
    }
    sigterm.resume()
    signal(SIGTERM, SIG_IGN)
    sigtermSource = sigterm

    // SIGINT handler
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler {
        print("wwkd: Received SIGINT, shutting down...")
        Task { @MainActor in
            ipcServerRef?.stop()
            try? await agentRef?.stop()
            Foundation.exit(0)
        }
    }
    sigint.resume()
    signal(SIGINT, SIG_IGN)
    sigintSource = sigint
}

/// Main entry point using @main struct
@main
struct WWKDMain {
    @MainActor
    static func main() async throws {
        print("wwkd: Starting WellWhaddyaKnow background agent v\(Agent.agentVersion)")

        // Parse command line for optional database path
        let args = CommandLine.arguments
        let dbPath: String
        if args.count > 1 {
            dbPath = args[1]
        } else {
            dbPath = getDefaultDatabasePath()
        }

        print("wwkd: Database path: \(dbPath)")

        // Set up signal handlers before starting
        setupSignalHandlers()

        // Create agent and configure sensors (two-phase initialization)
        let agent = try Agent(databasePath: dbPath)
        await agent.configureSensors()

        // Store global reference to keep agent alive
        agentRef = agent

        // Start the agent
        try await agent.start()
        print("wwkd: Agent started successfully")

        // Start IPC server for inter-process communication
        let service = await agent.createService()
        let socketPath = getIPCSocketPath()
        let ipcServer = IPCServer(socketPath: socketPath, service: service)
        do {
            try ipcServer.start()
            ipcServerRef = ipcServer
        } catch {
            print("wwkd: Warning - IPC server failed to start: \(error)")
            // Continue running even if IPC fails - CLI can still use direct DB reads
        }

        // Keep the process alive forever.
        // The Swift async main will keep running until we exit.
        // Sensors use NSWorkspace notifications and timers which are
        // processed by the Swift cooperative executor's run loop integration.
        // We just need to never return from main().
        while true {
            // Sleep for a long time, yielding to other tasks.
            // This keeps the process alive while allowing the
            // cooperative executor to process notification callbacks.
            try await Task.sleep(for: .seconds(86400)) // Sleep for 1 day
        }
    }
}
