// SPDX-License-Identifier: MIT
// TagCommand.swift - wwk tag commands per SPEC.md Section 10.2

import ArgumentParser
import Foundation

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
                    "created": formatLocalTimestamp(tag.createdTsUs),
                    "is_retired": tag.isRetired
                ]
                if let retired = tag.retiredTsUs {
                    dict["retired"] = formatLocalTimestamp(retired)
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
        // This command requires the agent to be running
        printError("Tag apply requires the agent (wwkd) to be running.")
        printError("This command will be available when XPC client integration is complete.")
        throw ExitCode.agentNotRunning
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
        printError("Tag remove requires the agent (wwkd) to be running.")
        throw ExitCode.agentNotRunning
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
        printError("Tag create requires the agent (wwkd) to be running.")
        throw ExitCode.agentNotRunning
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
        printError("Tag retire requires the agent (wwkd) to be running.")
        throw ExitCode.agentNotRunning
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
        printError("Tag rename requires the agent (wwkd) to be running.")
        throw ExitCode.agentNotRunning
    }
}

