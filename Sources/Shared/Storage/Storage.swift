// SPDX-License-Identifier: MIT
// Storage.swift - Public API for the Storage module

import Foundation

/// Storage module for well-whaddya-know.
/// Provides SQLite database management with:
/// - Schema initialization and migrations
/// - Connection configuration with required PRAGMAs
/// - Immutability enforcement via triggers
///
/// Usage:
/// ```swift
/// let connection = DatabaseConnection(path: "/path/to/wwk.sqlite")
/// try connection.open()
/// let schemaManager = SchemaManager(connection: connection)
/// try schemaManager.initializeSchema()
/// ```
public enum Storage {
    /// Current schema version
    public static var schemaVersion: Int32 { Schema.currentVersion }
}

