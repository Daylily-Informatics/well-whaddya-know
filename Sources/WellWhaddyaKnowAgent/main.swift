// SPDX-License-Identifier: MIT
// main.swift - Entry point for the wwkd background agent

import Foundation
import AppKit

/// Main entry point struct
@main
struct WWKDMain {

    /// Default database path in app support directory
    static func getDefaultDatabasePath() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("WellWhaddyaKnow", isDirectory: true)

        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

        return appDir.appendingPathComponent("wwk.sqlite").path
    }

    /// Main entry point - async main for Swift 6 concurrency
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

        do {
            // Create agent and configure sensors (two-phase initialization)
            let agent = try Agent(databasePath: dbPath)
            await agent.configureSensors()

            // Set up signal handlers for graceful shutdown
            let signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            signalSource.setEventHandler {
                Task {
                    print("wwkd: Received SIGTERM, shutting down...")
                    try? await agent.stop()
                    Foundation.exit(0)
                }
            }
            signalSource.resume()
            signal(SIGTERM, SIG_IGN)

            let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            sigintSource.setEventHandler {
                Task {
                    print("wwkd: Received SIGINT, shutting down...")
                    try? await agent.stop()
                    Foundation.exit(0)
                }
            }
            sigintSource.resume()
            signal(SIGINT, SIG_IGN)

            // Start the agent
            try await agent.start()
            print("wwkd: Agent started successfully")

            // Keep the process alive using dispatchMain() which runs the main dispatch queue
            // This allows run loop events (notifications) to be processed
            // We need to call this from a non-async context
            await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in
                DispatchQueue.main.async {
                    // This never returns - the process runs forever until a signal is received
                    dispatchMain()
                }
            }

        } catch {
            print("wwkd: Fatal error: \(error)")
            Foundation.exit(1)
        }
    }
}
