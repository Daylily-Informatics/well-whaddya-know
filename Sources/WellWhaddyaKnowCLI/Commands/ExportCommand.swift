// SPDX-License-Identifier: MIT
// ExportCommand.swift - wwk export command per SPEC.md Section 10.2

import ArgumentParser
import Foundation
import Reporting
import Timeline
import CoreModel

/// Export format options
enum ExportFormat: String, ExpressibleByArgument, CaseIterable {
    case csv
    case json
}

/// Export command - exports timeline data to CSV or JSON
struct Export: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Export timeline data to CSV or JSON"
    )

    @OptionGroup var options: GlobalOptions

    @Option(name: .long, help: "Start date (ISO 8601)")
    var from: String

    @Option(name: .long, help: "End date (ISO 8601)")
    var to: String

    @Option(name: .long, help: "Output format: csv or json")
    var format: ExportFormat

    @Option(name: .long, help: "Output path (use - for stdout)")
    var out: String

    @Option(name: .long, help: "Include window titles in export")
    var includeTitles: Bool = true

    mutating func run() async throws {
        let path = options.db ?? getDefaultDatabasePath()

        let tz = options.resolvedTimezone
        let startTsUs = try parseISODate(from, timeZone: tz)
        let endTsUs = try parseISODate(to, timeZone: tz)

        guard startTsUs < endTsUs else {
            printError("Start date must be before end date")
            throw ExitCode.invalidInput
        }

        let reader = try DatabaseReader(path: path)
        let segments = try reader.buildTimeline(startTsUs: startTsUs, endTsUs: endTsUs)
        let identity = try reader.loadIdentity()

        // Get timezone offset
        let tzOffsetSeconds = tz.secondsFromGMT()

        let output: String
        switch format {
        case .csv:
            output = CSVExporter.export(
                segments: segments,
                identity: identity,
                includeTitles: includeTitles,
                tzOffsetSeconds: tzOffsetSeconds
            )
        case .json:
            output = JSONExporter.export(
                segments: segments,
                identity: identity,
                range: (startTsUs, endTsUs),
                includeTitles: includeTitles
            )
        }

        // Write output
        if out == "-" {
            print(output)
        } else {
            do {
                // Atomic write: write to temp file then rename
                let tempPath = out + ".tmp"
                try output.write(toFile: tempPath, atomically: false, encoding: .utf8)
                let fm = FileManager.default
                if fm.fileExists(atPath: out) {
                    try fm.removeItem(atPath: out)
                }
                try fm.moveItem(atPath: tempPath, toPath: out)
                print("Exported to: \(out)")
            } catch {
                throw CLIError.exportFailed(message: error.localizedDescription)
            }
        }
    }
}

