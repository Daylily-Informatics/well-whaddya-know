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
        version: "0.3.4",
        subcommands: [
            Status.self,
            Summary.self,
            Today.self,
            Week.self,
            Export.self,
            Edit.self,
            Tag.self,
            Agent.self,
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

    @Option(name: .long, help: "Display timezone (IANA identifier, e.g. America/New_York). Default: GUI preference or system)")
    var timezone: String?

    /// Resolve the effective display timezone.
    /// Priority: --timezone flag → UserDefaults preference → system timezone.
    var resolvedTimezone: TimeZone {
        if let id = timezone, let tz = TimeZone(identifier: id) {
            return tz
        }
        // Fall back to the same UserDefaults key the GUI uses
        let key = "com.daylily.wellwhaddyaknow.displayTimezone"
        if let id = UserDefaults.standard.string(forKey: key),
           !id.isEmpty,
           let tz = TimeZone(identifier: id) {
            return tz
        }
        return TimeZone.current
    }

    /// A Calendar configured with the resolved display timezone.
    var resolvedCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = resolvedTimezone
        return cal
    }
}

// MARK: - Helpers

/// Get the default database path from App Group container (per SPEC.md Section 3)
/// Path: ~/Library/Group Containers/group.com.daylily.wellwhaddyaknow/WellWhaddyaKnow/wwk.sqlite
func getDefaultDatabasePath() -> String {
    let appGroupId = "group.com.daylily.wellwhaddyaknow"

    // Try the App Group container API first (works in sandboxed apps)
    if let containerURL = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupId
    ) {
        return containerURL
            .appendingPathComponent("WellWhaddyaKnow")
            .appendingPathComponent("wwk.sqlite")
            .path
    }

    // Fallback: construct the path directly for non-sandboxed command-line tools
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home
        .appendingPathComponent("Library/Group Containers")
        .appendingPathComponent(appGroupId)
        .appendingPathComponent("WellWhaddyaKnow")
        .appendingPathComponent("wwk.sqlite")
        .path
}

/// Parse ISO 8601 date string to timestamp in microseconds.
/// The `timeZone` parameter is used when parsing date-only strings (e.g. "2024-01-15").
func parseISODate(_ string: String, timeZone: TimeZone = .current) throws -> Int64 {
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
    
    // Try date-only format (interpreted in the given timezone)
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd"
    dateFormatter.timeZone = timeZone
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

/// Format timestamp to ISO string in the given timezone.
func formatLocalTimestamp(_ tsUs: Int64, timeZone: TimeZone = .current) -> String {
    let date = Date(timeIntervalSince1970: Double(tsUs) / 1_000_000.0)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = timeZone
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

