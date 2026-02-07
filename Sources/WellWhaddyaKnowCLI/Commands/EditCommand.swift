// SPDX-License-Identifier: MIT
// EditCommand.swift - wwk edit commands per SPEC.md Section 10.2

import ArgumentParser
import Foundation
import XPCProtocol

/// Edit command group - timeline editing operations
struct Edit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Edit timeline data",
        subcommands: [
            EditDelete.self,
            EditAdd.self,
            EditUndo.self,
        ]
    )
}

/// Delete a time range
struct EditDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a time range from timeline"
    )

    @OptionGroup var options: GlobalOptions

    @Option(name: .long, help: "Start date (ISO 8601)")
    var from: String

    @Option(name: .long, help: "End date (ISO 8601)")
    var to: String

    @Option(name: .long, help: "Note for this edit")
    var note: String?

    mutating func run() async throws {
        // Validate date range
        let startTsUs = try parseISODate(from, timeZone: options.resolvedTimezone)
        let endTsUs = try parseISODate(to, timeZone: options.resolvedTimezone)

        guard startTsUs < endTsUs else {
            printError("Start date must be before end date")
            throw ExitCode.invalidInput
        }

        let client = CLIIPCClient()

        do {
            let ueeId = try await client.deleteRange(from: startTsUs, to: endTsUs, note: note)
            if options.json {
                print("{\"success\": true, \"uee_id\": \(ueeId)}")
            } else {
                print("Deleted time range. Edit ID: \(ueeId)")
            }
        } catch CLIError.agentNotRunning {
            printError("Agent (wwkd) is not running. Start the agent first.")
            throw ExitCode.agentNotRunning
        } catch {
            printError(error.localizedDescription)
            throw ExitCode.databaseError
        }
    }
}

/// Add manual activity
struct EditAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add manual activity to timeline"
    )

    @OptionGroup var options: GlobalOptions

    @Option(name: .long, help: "Start date (ISO 8601)")
    var from: String

    @Option(name: .long, help: "End date (ISO 8601)")
    var to: String

    @Option(name: .long, help: "Application name")
    var appName: String

    @Option(name: .long, help: "Bundle ID (optional)")
    var bundleId: String?

    @Option(name: .long, help: "Window title (optional)")
    var title: String?

    @Option(name: .long, help: "Comma-separated tags (optional)")
    var tags: String?

    @Option(name: .long, help: "Note for this edit")
    var note: String?

    mutating func run() async throws {
        // Validate date range
        let startTsUs = try parseISODate(from, timeZone: options.resolvedTimezone)
        let endTsUs = try parseISODate(to, timeZone: options.resolvedTimezone)

        guard startTsUs < endTsUs else {
            printError("Start date must be before end date")
            throw ExitCode.invalidInput
        }

        // Parse comma-separated tags
        let tagList: [String]
        if let tagsStr = tags {
            tagList = tagsStr.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        } else {
            tagList = []
        }

        let client = CLIIPCClient()

        do {
            let ueeId = try await client.addRange(
                from: startTsUs,
                to: endTsUs,
                appName: appName,
                bundleId: bundleId,
                title: title,
                tags: tagList,
                note: note
            )
            if options.json {
                print("{\"success\": true, \"uee_id\": \(ueeId)}")
            } else {
                print("Added manual activity. Edit ID: \(ueeId)")
            }
        } catch CLIError.agentNotRunning {
            printError("Agent (wwkd) is not running. Start the agent first.")
            throw ExitCode.agentNotRunning
        } catch {
            printError(error.localizedDescription)
            throw ExitCode.databaseError
        }
    }
}

/// Undo a previous edit
struct EditUndo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "undo",
        abstract: "Undo a previous edit"
    )

    @OptionGroup var options: GlobalOptions

    @Option(name: .long, help: "User edit event ID to undo")
    var id: Int64

    mutating func run() async throws {
        let client = CLIIPCClient()

        do {
            let ueeId = try await client.undoEdit(targetUeeId: id)
            if options.json {
                print("{\"success\": true, \"uee_id\": \(ueeId)}")
            } else {
                print("Undid edit \(id). New edit ID: \(ueeId)")
            }
        } catch CLIError.agentNotRunning {
            printError("Agent (wwkd) is not running. Start the agent first.")
            throw ExitCode.agentNotRunning
        } catch {
            printError(error.localizedDescription)
            throw ExitCode.databaseError
        }
    }
}

