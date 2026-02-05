// SPDX-License-Identifier: MIT
// WWK.swift - Main CLI entry point per SPEC.md Section 10

import ArgumentParser
import Foundation

/// Main CLI entry point for well-whaddya-know
@main
struct WWK: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wwk",
        abstract: "WellWhaddyaKnow - macOS time tracking CLI",
        version: "0.1.0",
        subcommands: [
            Status.self,
            Summary.self,
            Today.self,
            Week.self,
            Export.self,
            Edit.self,
            Tag.self,
            Doctor.self,
            DB.self,
        ],
        defaultSubcommand: Status.self
    )
}

// MARK: - Global Options

/// Common options shared across commands
struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "Path to database file (default: app group container)")
    var db: String?

    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false
}

// MARK: - Helpers

/// Get the default database path from app group container
func getDefaultDatabasePath() -> String? {
    let appGroupId = "group.com.daylily.wellwhaddyaknow"
    guard let containerURL = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupId
    ) else {
        return nil
    }
    return containerURL
        .appendingPathComponent("WellWhaddyaKnow")
        .appendingPathComponent("wwk.sqlite")
        .path
}

/// Parse ISO 8601 date string to timestamp in microseconds
func parseISODate(_ string: String) throws -> Int64 {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    
    if let date = formatter.date(from: string) {
        return Int64(date.timeIntervalSince1970 * 1_000_000)
    }
    
    // Try without fractional seconds
    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: string) {
        return Int64(date.timeIntervalSince1970 * 1_000_000)
    }
    
    // Try date-only format
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd"
    dateFormatter.timeZone = TimeZone.current
    if let date = dateFormatter.date(from: string) {
        return Int64(date.timeIntervalSince1970 * 1_000_000)
    }
    
    throw ValidationError("Invalid date format: \(string). Use ISO 8601 format (e.g., 2024-01-15T09:00:00Z)")
}

/// Format duration in seconds to human-readable string
func formatDuration(_ seconds: Double) -> String {
    let hours = Int(seconds) / 3600
    let minutes = (Int(seconds) % 3600) / 60
    if hours > 0 {
        return "\(hours)h \(minutes)m"
    }
    return "\(minutes)m"
}

/// Format timestamp to local ISO string
func formatLocalTimestamp(_ tsUs: Int64) -> String {
    let date = Date(timeIntervalSince1970: Double(tsUs) / 1_000_000.0)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone.current
    return formatter.string(from: date)
}

/// Print error message to stderr
func printError(_ message: String) {
    FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
}

/// Exit codes per SPEC.md
enum ExitCode: Int32, Error {
    case success = 0
    case generalError = 1
    case agentNotRunning = 2
    case invalidInput = 3
    case databaseError = 4
}

