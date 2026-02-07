// SPDX-License-Identifier: MIT
// CLIError.swift - CLI error types

import Foundation

/// Errors that can occur during CLI operations
enum CLIError: Error, LocalizedError {
    case databaseNotFound(path: String)
    case databaseError(message: String)
    case agentNotRunning
    case invalidTimeRange(message: String)
    case invalidInput(message: String)
    case exportFailed(message: String)
    case tagNotFound(name: String)
    case tagAlreadyExists(name: String)

    var errorDescription: String? {
        switch self {
        case .databaseNotFound(let path):
            return """
            Database not found at: \(path)

            The wwkd agent may not be running or has never been started.

            To start the agent:
              wwk agent install    # Install as login item (starts at login)
              wwk agent start      # Start now

            To check agent status:
              wwk agent status
            """
        case .databaseError(let message):
            return "Database error: \(message)"
        case .agentNotRunning:
            return "Agent is not running. Start wwkd first for mutating operations."
        case .invalidTimeRange(let message):
            return "Invalid time range: \(message)"
        case .invalidInput(let message):
            return "Invalid input: \(message)"
        case .exportFailed(let message):
            return "Export failed: \(message)"
        case .tagNotFound(let name):
            return "Tag not found: \(name)"
        case .tagAlreadyExists(let name):
            return "Tag already exists: \(name)"
        }
    }
}

