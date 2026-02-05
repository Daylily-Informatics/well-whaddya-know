// SPDX-License-Identifier: MIT
// SummaryCommands.swift - wwk summary, today, week commands per SPEC.md Section 10.2

import ArgumentParser
import Foundation
import Reporting
import Timeline

/// Group-by options for summary
enum GroupBy: String, ExpressibleByArgument, CaseIterable {
    case app
    case title
    case tag
    case day
}

/// Summary command - shows time summary for a date range
struct Summary: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show time summary for a date range"
    )

    @OptionGroup var options: GlobalOptions

    @Option(name: .long, help: "Start date (ISO 8601)")
    var from: String

    @Option(name: .long, help: "End date (ISO 8601)")
    var to: String

    @Option(name: .long, help: "Group by: app, title, tag, or day")
    var groupBy: GroupBy = .app

    mutating func run() async throws {
        let dbPath = options.db ?? getDefaultDatabasePath()
        guard let path = dbPath else {
            printError("Database path not found")
            throw ExitCode.databaseError
        }

        let startTsUs = try parseISODate(from)
        let endTsUs = try parseISODate(to)

        guard startTsUs < endTsUs else {
            printError("Start date must be before end date")
            throw ExitCode.invalidInput
        }

        let reader = try DatabaseReader(path: path)
        let segments = try reader.buildTimeline(startTsUs: startTsUs, endTsUs: endTsUs)

        let totals: [String: Double]
        switch groupBy {
        case .app:
            totals = Aggregations.totalsByApplication(segments: segments)
        case .title:
            totals = Aggregations.totalsByWindowTitle(segments: segments)
        case .tag:
            totals = Aggregations.totalsByTag(segments: segments)
        case .day:
            totals = Aggregations.totalsByDay(segments: segments, timeZone: .current)
        }

        if options.json {
            let output: [String: Any] = [
                "from": from,
                "to": to,
                "group_by": groupBy.rawValue,
                "totals": totals.mapValues { $0 }
            ]
            if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                print(json)
            }
        } else {
            print("Summary from \(from) to \(to) (grouped by \(groupBy.rawValue)):")
            print("")
            let sorted = totals.sorted { $0.value > $1.value }
            for (key, seconds) in sorted {
                print("  \(key): \(formatDuration(seconds))")
            }
            print("")
            print("Total: \(formatDuration(Aggregations.totalWorkingTime(segments: segments)))")
        }
    }
}

/// Today command - shows today's summary
struct Today: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show today's time summary"
    )

    @OptionGroup var options: GlobalOptions

    mutating func run() async throws {
        let dbPath = options.db ?? getDefaultDatabasePath()
        guard let path = dbPath else {
            printError("Database path not found")
            throw ExitCode.databaseError
        }

        let calendar = Calendar.current
        let now = Date()
        let startOfDay = calendar.startOfDay(for: now)
        let startTsUs = Int64(startOfDay.timeIntervalSince1970 * 1_000_000)
        let endTsUs = Int64(now.timeIntervalSince1970 * 1_000_000)

        let reader = try DatabaseReader(path: path)
        let segments = try reader.buildTimeline(startTsUs: startTsUs, endTsUs: endTsUs)
        let total = Aggregations.totalWorkingTime(segments: segments)
        let byApp = Aggregations.totalsByApplication(segments: segments)

        if options.json {
            let output: [String: Any] = [
                "date": ISO8601DateFormatter().string(from: startOfDay),
                "total_seconds": total,
                "by_app": byApp
            ]
            if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                print(json)
            }
        } else {
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .full
            print("Today (\(dateFormatter.string(from: now))):")
            print("")
            print("  Total: \(formatDuration(total))")
            print("")
            if !byApp.isEmpty {
                print("  By Application:")
                let sorted = byApp.sorted { $0.value > $1.value }
                for (app, seconds) in sorted.prefix(5) {
                    print("    \(app): \(formatDuration(seconds))")
                }
            }
        }
    }
}

/// Week command - shows this week's summary
struct Week: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show this week's time summary"
    )

    @OptionGroup var options: GlobalOptions

    mutating func run() async throws {
        let dbPath = options.db ?? getDefaultDatabasePath()
        guard let path = dbPath else {
            printError("Database path not found")
            throw ExitCode.databaseError
        }

        let calendar = Calendar.current
        let now = Date()

        // Get start of week (Sunday or Monday depending on locale)
        guard let weekInterval = calendar.dateInterval(of: .weekOfYear, for: now) else {
            printError("Could not determine week boundaries")
            throw ExitCode.generalError
        }

        let startTsUs = Int64(weekInterval.start.timeIntervalSince1970 * 1_000_000)
        let endTsUs = Int64(now.timeIntervalSince1970 * 1_000_000)

        let reader = try DatabaseReader(path: path)
        let segments = try reader.buildTimeline(startTsUs: startTsUs, endTsUs: endTsUs)
        let total = Aggregations.totalWorkingTime(segments: segments)
        let byDay = Aggregations.totalsByDay(segments: segments, timeZone: .current)

        if options.json {
            let output: [String: Any] = [
                "week_start": ISO8601DateFormatter().string(from: weekInterval.start),
                "total_seconds": total,
                "by_day": byDay
            ]
            if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                print(json)
            }
        } else {
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .medium
            print("This Week (starting \(dateFormatter.string(from: weekInterval.start))):")
            print("")
            print("  Total: \(formatDuration(total))")
            print("")
            if !byDay.isEmpty {
                print("  By Day:")
                let sorted = byDay.sorted { $0.key < $1.key }
                for (day, seconds) in sorted {
                    print("    \(day): \(formatDuration(seconds))")
                }
            }
        }
    }
}

