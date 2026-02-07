// SPDX-License-Identifier: MIT
// TagCommand.swift - wwk tag commands per SPEC.md Section 10.2

import ArgumentParser
import Foundation
import XPCProtocol

/// Tag command group
struct Tag: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage tags",
        subcommands: [
            TagList.self,
            TagApply.self,
            TagRemove.self,
            TagCreate.self,
            TagRetire.self,
            TagRename.self,
        ],
        defaultSubcommand: TagList.self
    )
}

/// List all tags
struct TagList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all tags"
    )

    @OptionGroup var options: GlobalOptions

    mutating func run() async throws {
        let path = options.db ?? getDefaultDatabasePath()

        let reader = try DatabaseReader(path: path)
        let tags = try reader.loadTags()

        if options.json {
            let output: [[String: Any]] = tags.map { tag in
                var dict: [String: Any] = [
                    "tag_id": tag.tagId,
                    "name": tag.name,
                    "created": formatLocalTimestamp(tag.createdTsUs, timeZone: options.resolvedTimezone),
                    "is_retired": tag.isRetired
                ]
                if let retired = tag.retiredTsUs {
                    dict["retired"] = formatLocalTimestamp(retired, timeZone: options.resolvedTimezone)
                }
                return dict
            }
            if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                print(json)
            }
        } else {
            if tags.isEmpty {
                print("No tags defined.")
            } else {
                print("Tags:")
                for tag in tags {
                    let status = tag.isRetired ? " (retired)" : ""
                    print("  \(tag.name)\(status)")
                }
            }
        }
    }
}

/// Apply a tag to a time range (requires agent)
struct TagApply: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apply",
        abstract: "Apply a tag to a time range"
    )

    @OptionGroup var options: GlobalOptions

    @Option(name: .long, help: "Start date (ISO 8601)")
    var from: String

    @Option(name: .long, help: "End date (ISO 8601)")
    var to: String

    @Option(name: .long, help: "Tag name to apply")
    var tag: String

    mutating func run() async throws {
        let startTsUs = try parseISODate(from, timeZone: options.resolvedTimezone)
        let endTsUs = try parseISODate(to, timeZone: options.resolvedTimezone)

        guard startTsUs < endTsUs else {
            printError("Start date must be before end date")
            throw ExitCode.invalidInput
        }

        let client = CLIIPCClient()

        do {
            let ueeId = try await client.applyTag(from: startTsUs, to: endTsUs, tagName: tag)
            if options.json {
                print("{\"success\": true, \"uee_id\": \(ueeId)}")
            } else {
                print("Applied tag '\(tag)'. Edit ID: \(ueeId)")
            }
        } catch CLIError.agentNotRunning {
            printError("Agent (wwkd) is not running. Start the agent first.")
            throw ExitCode.agentNotRunning
        } catch CLIError.tagNotFound(let name) {
            printError("Tag not found: \(name)")
            throw ExitCode.invalidInput
        } catch {
            printError(error.localizedDescription)
            throw ExitCode.databaseError
        }
    }
}

/// Remove a tag from a time range (requires agent)
struct TagRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a tag from a time range"
    )

    @OptionGroup var options: GlobalOptions

    @Option(name: .long, help: "Start date (ISO 8601)")
    var from: String

    @Option(name: .long, help: "End date (ISO 8601)")
    var to: String

    @Option(name: .long, help: "Tag name to remove")
    var tag: String

    mutating func run() async throws {
        let startTsUs = try parseISODate(from, timeZone: options.resolvedTimezone)
        let endTsUs = try parseISODate(to, timeZone: options.resolvedTimezone)

        guard startTsUs < endTsUs else {
            printError("Start date must be before end date")
            throw ExitCode.invalidInput
        }

        let client = CLIIPCClient()

        do {
            let ueeId = try await client.removeTag(from: startTsUs, to: endTsUs, tagName: tag)
            if options.json {
                print("{\"success\": true, \"uee_id\": \(ueeId)}")
            } else {
                print("Removed tag '\(tag)'. Edit ID: \(ueeId)")
            }
        } catch CLIError.agentNotRunning {
            printError("Agent (wwkd) is not running. Start the agent first.")
            throw ExitCode.agentNotRunning
        } catch CLIError.tagNotFound(let name) {
            printError("Tag not found: \(name)")
            throw ExitCode.invalidInput
        } catch {
            printError(error.localizedDescription)
            throw ExitCode.databaseError
        }
    }
}

/// Create a new tag (requires agent)
struct TagCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new tag"
    )

    @OptionGroup var options: GlobalOptions

    @Option(name: .long, help: "Tag name")
    var name: String

    mutating func run() async throws {
        let client = CLIIPCClient()

        do {
            let tagId = try await client.createTag(name: name)
            if options.json {
                print("{\"success\": true, \"tag_id\": \(tagId)}")
            } else {
                print("Created tag '\(name)'. Tag ID: \(tagId)")
            }
        } catch CLIError.agentNotRunning {
            printError("Agent (wwkd) is not running. Start the agent first.")
            throw ExitCode.agentNotRunning
        } catch CLIError.tagAlreadyExists(let existingName) {
            printError("Tag already exists: \(existingName)")
            throw ExitCode.invalidInput
        } catch {
            printError(error.localizedDescription)
            throw ExitCode.databaseError
        }
    }
}

/// Retire a tag (requires agent)
struct TagRetire: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "retire",
        abstract: "Retire a tag"
    )

    @OptionGroup var options: GlobalOptions

    @Option(name: .long, help: "Tag name to retire")
    var name: String

    mutating func run() async throws {
        let client = CLIIPCClient()

        do {
            try await client.retireTag(name: name)
            if options.json {
                print("{\"success\": true}")
            } else {
                print("Retired tag '\(name)'")
            }
        } catch CLIError.agentNotRunning {
            printError("Agent (wwkd) is not running. Start the agent first.")
            throw ExitCode.agentNotRunning
        } catch CLIError.tagNotFound(let missingName) {
            printError("Tag not found: \(missingName)")
            throw ExitCode.invalidInput
        } catch {
            printError(error.localizedDescription)
            throw ExitCode.databaseError
        }
    }
}

/// Rename a tag (create new + retire old)
struct TagRename: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rename",
        abstract: "Rename a tag"
    )

    @OptionGroup var options: GlobalOptions

    @Option(name: .customLong("from"), help: "Old tag name")
    var fromName: String

    @Option(name: .customLong("to"), help: "New tag name")
    var toName: String

    mutating func run() async throws {
        let client = CLIIPCClient()

        do {
            // Create the new tag first
            let tagId = try await client.createTag(name: toName)
            // Then retire the old tag
            try await client.retireTag(name: fromName)

            if options.json {
                print("{\"success\": true, \"new_tag_id\": \(tagId)}")
            } else {
                print("Renamed tag '\(fromName)' to '\(toName)'. New tag ID: \(tagId)")
            }
        } catch CLIError.agentNotRunning {
            printError("Agent (wwkd) is not running. Start the agent first.")
            throw ExitCode.agentNotRunning
        } catch CLIError.tagNotFound(let missingName) {
            printError("Tag not found: \(missingName)")
            throw ExitCode.invalidInput
        } catch CLIError.tagAlreadyExists(let existingName) {
            printError("Tag already exists: \(existingName)")
            throw ExitCode.invalidInput
        } catch {
            printError(error.localizedDescription)
            throw ExitCode.databaseError
        }
    }
}

