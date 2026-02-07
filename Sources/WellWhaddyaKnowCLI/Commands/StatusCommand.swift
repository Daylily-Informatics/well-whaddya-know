// SPDX-License-Identifier: MIT
// StatusCommand.swift - wwk status command per SPEC.md Section 10.2

import ArgumentParser
import Foundation
import XPCProtocol

/// Status command - shows current agent status
struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show current agent status"
    )

    @OptionGroup var options: GlobalOptions

    mutating func run() async throws {
        // For now, we can't connect to the agent via XPC from CLI
        // because the agent doesn't have a proper XPC listener yet.
        // Instead, we'll show database-based status.

        let path = options.db ?? getDefaultDatabasePath()

        do {
            let reader = try DatabaseReader(path: path)
            
            // Get latest activity event to determine current state
            let now = Date()
            let endTsUs = Int64(now.timeIntervalSince1970 * 1_000_000)
            let startTsUs = endTsUs - (60 * 1_000_000) // Last minute
            
            let segments = try reader.buildTimeline(startTsUs: startTsUs, endTsUs: endTsUs)
            let lastSegment = segments.last
            
            let isWorking = lastSegment != nil && lastSegment!.endTsUs >= endTsUs - (5 * 1_000_000)
            let currentApp = lastSegment?.appName
            let currentTitle = lastSegment?.windowTitle
            
            if options.json {
                let output: [String: Any] = [
                    "is_working": isWorking,
                    "current_app": currentApp as Any,
                    "current_title": currentTitle as Any,
                    "accessibility_status": "unknown",
                    "agent_version": "0.3.2"
                ]
                if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]),
                   let json = String(data: data, encoding: .utf8) {
                    print(json)
                }
            } else {
                print("Status: \(isWorking ? "Working" : "Not working")")
                if let app = currentApp {
                    print("Current App: \(app)")
                }
                if let title = currentTitle {
                    print("Current Title: \(title)")
                }
                print("Accessibility: unknown (check via agent)")
                print("Agent Version: 0.3.2")
            }
        } catch let error as CLIError {
            if options.json {
                print(#"{"error": "\#(error.localizedDescription)"}"#)
            } else {
                printError(error.localizedDescription)
            }
            throw ExitCode.databaseError
        }
    }
}

