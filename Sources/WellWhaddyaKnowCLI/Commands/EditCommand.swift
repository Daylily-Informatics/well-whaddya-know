// SPDX-License-Identifier: MIT
// EditCommand.swift - wwk edit commands per SPEC.md Section 10.2

import ArgumentParser
import Foundation

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
        let startTsUs = try parseISODate(from)
        let endTsUs = try parseISODate(to)

        guard startTsUs < endTsUs else {
            printError("Start date must be before end date")
            throw ExitCode.invalidInput
        }

        // This command requires the agent to be running
        printError("Edit delete requires the agent (wwkd) to be running.")
        printError("This command will be available when XPC client integration is complete.")
        throw ExitCode.agentNotRunning
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
        let startTsUs = try parseISODate(from)
        let endTsUs = try parseISODate(to)

        guard startTsUs < endTsUs else {
            printError("Start date must be before end date")
            throw ExitCode.invalidInput
        }

        printError("Edit add requires the agent (wwkd) to be running.")
        printError("This command will be available when XPC client integration is complete.")
        throw ExitCode.agentNotRunning
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
        printError("Edit undo requires the agent (wwkd) to be running.")
        printError("This command will be available when XPC client integration is complete.")
        throw ExitCode.agentNotRunning
    }
}

