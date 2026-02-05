// SPDX-License-Identifier: MIT
// DBCommand.swift - wwk db commands per SPEC.md Section 10.2

import ArgumentParser
import Foundation

/// DB command group - database operations
struct DB: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Database operations",
        subcommands: [
            DBVerify.self,
            DBInfo.self,
        ],
        defaultSubcommand: DBInfo.self
    )
}

/// Verify database integrity
struct DBVerify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Verify database integrity"
    )

    @OptionGroup var options: GlobalOptions

    mutating func run() async throws {
        let dbPath = options.db ?? getDefaultDatabasePath()
        guard let path = dbPath else {
            printError("Database path not found")
            throw ExitCode.databaseError
        }

        let reader = try DatabaseReader(path: path)
        let isValid = try reader.verifyIntegrity()

        if options.json {
            let output: [String: Any] = [
                "path": path,
                "integrity_check": isValid ? "ok" : "failed"
            ]
            if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                print(json)
            }
        } else {
            print("Database: \(path)")
            print("Integrity check: \(isValid ? "✓ OK" : "✗ FAILED")")
        }

        if !isValid {
            throw ExitCode.databaseError
        }
    }
}

/// Show database info
struct DBInfo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Show database information"
    )

    @OptionGroup var options: GlobalOptions

    mutating func run() async throws {
        let dbPath = options.db ?? getDefaultDatabasePath()
        guard let path = dbPath else {
            printError("Database path not found")
            throw ExitCode.databaseError
        }

        let reader = try DatabaseReader(path: path)
        let schemaVersion = try reader.getSchemaVersion()
        let counts = try reader.getEventCounts()
        let dateRange = try reader.getDateRange()

        if options.json {
            var output: [String: Any] = [
                "path": path,
                "schema_version": schemaVersion,
                "event_counts": [
                    "system_state_events": counts.sse,
                    "raw_activity_events": counts.rae,
                    "user_edit_events": counts.uee,
                    "tags": counts.tags
                ]
            ]
            if let earliest = dateRange.earliest {
                output["earliest_event"] = formatLocalTimestamp(earliest)
            }
            if let latest = dateRange.latest {
                output["latest_event"] = formatLocalTimestamp(latest)
            }
            if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                print(json)
            }
        } else {
            print("Database Information")
            print("====================")
            print("Path: \(path)")
            print("Schema Version: \(schemaVersion)")
            print("")
            print("Event Counts:")
            print("  System State Events: \(counts.sse)")
            print("  Raw Activity Events: \(counts.rae)")
            print("  User Edit Events: \(counts.uee)")
            print("  Tags: \(counts.tags)")
            print("")
            if let earliest = dateRange.earliest, let latest = dateRange.latest {
                print("Date Range:")
                print("  Earliest: \(formatLocalTimestamp(earliest))")
                print("  Latest: \(formatLocalTimestamp(latest))")
            } else {
                print("Date Range: No events recorded")
            }
        }
    }
}

